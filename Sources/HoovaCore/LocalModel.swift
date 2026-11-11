import Foundation
import HuggingFace
import os

private let log = Logger(subsystem: "com.teayouness.hoova", category: "modèle")

/// Le dossier du modèle propre à Hoova, dans ~/Library/Application Support/Hoova/Modèles. Il ne garde que ce qui sert :
/// pas les parties son et image de Gemma (1 Go jamais chargé), et sa grande table dans un fichier à part, que MLX ne
/// charge pas (`MappedEmbedding` la lit directement). Résultat : 4,2 Go sur le disque au lieu de 5,2, et plus de pic de
/// mémoire au lancement. Il est préparé une fois, à partir du modèle publié sur Hugging Face.
public enum LocalModel {
    private static let root = URL.applicationSupportDirectory.appending(path: "Hoova/Modèles", directoryHint: .isDirectory)
    /// Les poids que Hoova n'utilise jamais : la vision et l'audio.
    private static let unused = [
        "audio_tower", "embed_audio", "vision_tower", "embed_vision", "multi_modal_projector", "vision_embedder",
    ]

    /// Le dossier allégé de ce modèle, préparé la première fois. Nil si le modèle n'a pas de grande table par couche :
    /// il se charge alors tel quel. `progress` suit la préparation, de 0 à 0,95 (le chargement fait le reste).
    static func directory(
        for id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL? {
        let destination = folder(of: id)
        if isReady(id) { return destination }
        // Le modèle déjà téléchargé dans le cache partagé de Hugging Face, sinon un téléchargement à Hoova.
        log.notice("Préparation du dossier du modèle")
        if let shared = sharedSnapshot(of: id) {
            return try split(shared, into: destination) { progress(0.95 * $0) } ? destination : nil
        }
        // Le téléchargement reste sur le disque tant que le dossier n'est pas prêt : une coupure (réseau, arrêt de Hoova)
        // ne fait perdre que le morceau en cours. Il est effacé une fois le dossier prêt.
        let download = downloadFolder(of: id)
        try await Download.model(
            id, revision: revision(of: id), into: download, extensions: ["json", "jinja", "safetensors"]
        ) {
            progress(0.8 * $0)
        }
        let ready = try split(download, into: destination) { progress(0.8 + 0.15 * $0) }
        try? FileManager.default.removeItem(at: download)
        return ready ? destination : nil
    }

    /// Le dossier de ce modèle est prêt sur ce Mac.
    public static func isReady(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(of: id).appending(path: MappedEmbedding.fileName).path)
    }

    /// Ce qui est déjà téléchargé d'un modèle pas encore prêt, en octets : le téléchargement reprendra de là.
    public static func downloaded(_ id: String) -> Int64 { size(at: downloadFolder(of: id)) }

    /// Le modèle est déjà dans le cache partagé de Hugging Face : rien à télécharger, seulement le dossier à préparer.
    public static func hasSharedCopy(_ id: String) -> Bool { sharedSnapshot(of: id) != nil }

    /// La place libre sur le disque des modèles, en octets, telle que macOS la compte pour un téléchargement voulu par
    /// l'utilisateur (en libérant ses caches au besoin).
    public static var freeSpace: Int64 {
        let values = try? URL.applicationSupportDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// La place que prend son dossier sur le disque, en octets.
    public static func size(of id: String) -> Int64 { size(at: folder(of: id)) }

    private static func size(at folder: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Met son dossier à la corbeille : jamais supprimé pour de bon, c'est à l'utilisateur de vider la corbeille.
    public static func trash(_ id: String) throws {
        try FileManager.default.trashItem(at: folder(of: id), resultingItemURL: nil)
    }

    private static func folder(of id: String) -> URL {
        root.appending(path: id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }

    private static func downloadFolder(of id: String) -> URL {
        root.appending(path: "Téléchargement", directoryHint: .isDirectory)
            .appending(path: id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }

    /// Un instantané complet du modèle dans le cache partagé de Hugging Face, s'il y en a un, à la version de Hoova.
    private static func sharedSnapshot(of id: String) -> URL? {
        let snapshots = HubCache().cacheDirectory
            .appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
            .appending(path: "snapshots", directoryHint: .isDirectory)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        let pinned = revision(of: id)
        return candidates.first {
            (pinned == "main" || $0.lastPathComponent == pinned)
                && FileManager.default.fileExists(atPath: $0.appending(path: "config.json").path)
                && FileManager.default.fileExists(atPath: $0.appending(path: "model.safetensors").path)
        }
    }

    /// La version à télécharger : celle de `LocalChoice`, sinon la dernière publiée (un autre modèle, pour les essais).
    private static func revision(of id: String) -> String { LocalChoice(rawValue: id)?.revision ?? "main" }

    /// Sépare les poids : le cœur du modèle dans model.safetensors, la grande table dans son propre fichier, sans les
    /// parties son et image. Écrit dans un dossier temporaire renommé à la fin : un dossier à moitié écrit ne sert jamais.
    private static func split(_ source: URL, into destination: URL, progress: (Double) -> Void) throws -> Bool {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        var core: [Tensor] = []
        var table: [Tensor] = []
        var metadata: [String: String] = [:]
        for url in files where url.pathExtension == "safetensors" {
            let data = try Data(contentsOf: url.resolvingSymlinksInPath(), options: .alwaysMapped)
            let header = try SafetensorsHeader(data)
            metadata.merge(header.metadata) { first, _ in first }
            for (name, entry) in header.entries
            where !unused.contains(where: { name.hasPrefix($0) || name.hasPrefix("model." + $0) }) {
                let tensor = Tensor(name: name, entry: entry, file: data)
                if name.contains("embed_tokens_per_layer.") { table.append(tensor) } else { core.append(tensor) }
            }
        }
        guard !table.isEmpty else { return false }

        let partial = destination.appendingPathExtension("partiel")
        try? manager.removeItem(at: partial)
        try manager.createDirectory(at: partial, withIntermediateDirectories: true)
        let total = Double(max((core + table).reduce(0) { $0 + $1.entry.size }, 1))
        var written = 0
        let advance = { (bytes: Int) in
            written += bytes
            progress(Double(written) / total)
        }
        try write(core, metadata: metadata, to: partial.appending(path: "model.safetensors"), written: advance)
        try write(table, metadata: metadata, to: partial.appending(path: MappedEmbedding.fileName), written: advance)
        // La configuration, le tokenizer et le modèle de conversation. Pas l'index des poids : il nommerait l'ancien
        // découpage.
        for url in files
        where url.pathExtension != "safetensors" && url.pathExtension != "md" && !url.lastPathComponent.hasPrefix(".")
            && url.lastPathComponent != "model.safetensors.index.json"
        {
            try manager.copyItem(at: url.resolvingSymlinksInPath(), to: partial.appending(path: url.lastPathComponent))
        }
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: partial, to: destination)
        log.notice("Dossier du modèle prêt")
        return true
    }

    private struct Tensor {
        let name: String
        let entry: SafetensorsHeader.Entry
        let file: Data
    }

    /// Écrit un fichier safetensors : 8 octets de longueur, l'en-tête JSON complété d'espaces jusqu'à un multiple de 8,
    /// puis les octets de chaque tenseur, recopiés morceau par morceau depuis le fichier d'origine.
    private static func write(
        _ tensors: [Tensor], metadata: [String: String], to url: URL, written: (Int) -> Void
    ) throws {
        let ordered = tensors.sorted { $0.name < $1.name }
        var header: [String: Any] = ["__metadata__": metadata]
        var offset = 0
        for tensor in ordered {
            header[tensor.name] = [
                "dtype": tensor.entry.dtype, "shape": tensor.entry.shape, "data_offsets": [offset, offset + tensor.entry.size],
            ]
            offset += tensor.entry.size
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while json.count % 8 != 0 { json.append(0x20) }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: withUnsafeBytes(of: UInt64(json.count).littleEndian) { Data($0) })
        try handle.write(contentsOf: json)
        let chunk = 64 << 20
        for tensor in ordered {
            var start = tensor.entry.offset
            let end = tensor.entry.offset + tensor.entry.size
            while start < end {
                let stop = min(start + chunk, end)
                try handle.write(contentsOf: tensor.file.subdata(in: start ..< stop))
                written(stop - start)
                start = stop
            }
        }
    }
}
