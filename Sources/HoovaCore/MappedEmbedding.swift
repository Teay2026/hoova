import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// La grande table de Gemma (« per-layer embeddings », 1,6 Go sur 4,2) lue directement dans son fichier au lieu
/// d'être chargée en mémoire : pour chaque mot, le modèle n'en lit qu'une ligne d'environ 5 Ko. Les pages lues restent
/// liées au fichier : sous pression, macOS les libère sans rien écrire dans le swap, et les relit au besoin.
///
/// Le calcul reste celui de `QuantizedEmbedding` : mêmes lignes, même déquantification, donc mêmes réponses.
final class MappedEmbedding: QuantizedEmbedding {
    /// Le fichier de la table, à côté des autres poids du modèle (format safetensors). Son extension le cache au
    /// chargeur de MLX, qui ne charge que les `.safetensors`.
    static let fileName = "per_layer_embeddings.bin"

    private let file: Data
    private let weightOffset: Int
    private let scalesOffset: Int
    private let biasesOffset: Int
    /// Par ligne : les entiers de 32 bits qui portent les valeurs quantifiées, et les groupes qui partagent une échelle.
    private let packed: Int
    private let groups: Int

    private init(
        file: Data, weightOffset: Int, scalesOffset: Int, biasesOffset: Int, packed: Int, groups: Int,
        groupSize: Int, bits: Int
    ) {
        self.file = file
        self.weightOffset = weightOffset
        self.scalesOffset = scalesOffset
        self.biasesOffset = biasesOffset
        self.packed = packed
        self.groups = groups
        super.init(
            weight: MLXArray.zeros([1, 1], dtype: .uint32), scales: MLXArray.zeros([1, 1], dtype: .bfloat16),
            biases: MLXArray.zeros([1, 1], dtype: .bfloat16), groupSize: groupSize, bits: bits)
    }

    /// Aucun paramètre pour MLX : le chargeur ne cherche pas cette table dans les poids, et ne la charge jamais.
    override func items() -> ModuleItems {
        ModuleItems()
    }

    override func callAsFunction(_ x: MLXArray) -> MLXArray {
        let ids = x.flattened().asArray(Int32.self)
        var weight = [UInt32](repeating: 0, count: ids.count * packed)
        var scales = [Float](repeating: 0, count: ids.count * groups)
        var biases = [Float](repeating: 0, count: ids.count * groups)
        file.withUnsafeBytes { raw in
            weight.withUnsafeMutableBytes { rows in
                for (row, id) in ids.enumerated() {
                    let size = packed * MemoryLayout<UInt32>.size
                    rows.baseAddress!.advanced(by: row * size)
                        .copyMemory(from: raw.baseAddress!.advanced(by: weightOffset + Int(id) * size), byteCount: size)
                }
            }
            // bfloat16 → Float : les 16 bits du haut d'un Float, sans perte.
            for (row, id) in ids.enumerated() {
                for group in 0 ..< groups {
                    let offset = (Int(id) * groups + group) * 2
                    let scale = raw.loadUnaligned(fromByteOffset: scalesOffset + offset, as: UInt16.self)
                    let bias = raw.loadUnaligned(fromByteOffset: biasesOffset + offset, as: UInt16.self)
                    scales[row * groups + group] = Float(bitPattern: UInt32(scale) << 16)
                    biases[row * groups + group] = Float(bitPattern: UInt32(bias) << 16)
                }
            }
        }
        let out = dequantized(
            MLXArray(weight, [ids.count, packed]),
            scales: MLXArray(scales, [ids.count, groups]).asType(.bfloat16),
            biases: MLXArray(biases, [ids.count, groups]).asType(.bfloat16),
            groupSize: groupSize, bits: bits)
        return out.reshaped(x.shape + [-1])
    }

    /// Fait créer les modèles Gemma 4 avec leur table lue dans `file`, avant même le chargement des poids : MLX ne
    /// charge donc jamais la table. Vaut pour tous les chargements suivants de Gemma 4 dans l'app.
    static func register(file: URL) async {
        await LLMTypeRegistry.shared.registerModelType("gemma4") { data in
            let model = Gemma4Model(try JSONDecoder().decode(Gemma4Configuration.self, from: data))
            guard try install(in: model, file: file) else { throw CocoaError(.fileReadCorruptFile) }
            return model
        }
    }

    /// Remplace la table du modèle par sa lecture dans `file`. Renvoie faux si le modèle n'a pas de telle table, ou si
    /// le fichier ne correspond pas (taille, format) : le modèle reste alors tel quel.
    static func install(in model: Module, file: URL) throws -> Bool {
        guard
            let (path, module) = model.namedModules().first(where: { $0.0.hasSuffix("embed_tokens_per_layer") }),
            let current = module as? Embedding
        else { return false }
        let (rows, dimensions) = current.shape
        let data = try Data(contentsOf: file, options: .alwaysMapped)
        let tensors = try SafetensorsHeader(data)
        guard let weight = tensors.entry(endingWith: "embed_tokens_per_layer.weight"),
            let scales = tensors.entry(endingWith: "embed_tokens_per_layer.scales"),
            let biases = tensors.entry(endingWith: "embed_tokens_per_layer.biases"),
            weight.dtype == "U32", scales.dtype == "BF16", biases.dtype == "BF16",
            weight.shape.count == 2, weight.shape[0] == rows, scales.shape == biases.shape,
            scales.shape == [rows, scales.shape.last ?? 0], (weight.shape[1] * 32) % dimensions == 0,
            let groups = scales.shape.last, groups > 0, dimensions % groups == 0
        else { return false }
        let mapped = MappedEmbedding(
            file: data, weightOffset: weight.offset, scalesOffset: scales.offset, biasesOffset: biases.offset,
            packed: weight.shape[1], groups: groups, groupSize: dimensions / groups,
            bits: weight.shape[1] * 32 / dimensions)
        model.update(modules: ModuleChildren.unflattened([(path, mapped)]))
        return true
    }
}

/// L'en-tête d'un fichier safetensors : pour chaque tenseur, son type, sa forme et la position de ses octets.
struct SafetensorsHeader {
    struct Entry: Decodable {
        let dtype: String
        let shape: [Int]
        let dataOffsets: [Int]
        /// Position dans le fichier : après les 8 octets de longueur et l'en-tête JSON.
        var offset = 0
        var size: Int { (dataOffsets.last ?? 0) - (dataOffsets.first ?? 0) }

        enum CodingKeys: String, CodingKey {
            case dtype, shape
            case dataOffsets = "data_offsets"
        }
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var metadata: [String: String] = [:]

    init(_ file: Data) throws {
        let length = Int(file.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
        let json = try JSONSerialization.jsonObject(with: file.subdata(in: 8 ..< 8 + length)) as? [String: Any] ?? [:]
        metadata = json["__metadata__"] as? [String: String] ?? [:]
        for (name, value) in json where name != "__metadata__" {
            guard let raw = try? JSONSerialization.data(withJSONObject: value),
                var entry = try? JSONDecoder().decode(Entry.self, from: raw)
            else { continue }
            entry.offset = 8 + length + (entry.dataOffsets.first ?? 0)
            entries[name] = entry
        }
    }

    func entry(endingWith suffix: String) -> Entry? {
        entries.first { $0.key.hasSuffix(suffix) }?.value
    }
}
