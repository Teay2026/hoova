import Foundation

/// Télécharge les fichiers d'un modèle publié sur Hugging Face en reprenant là où il s'était arrêté. Les octets reçus sont
/// écrits au fur et à mesure dans `<fichier>.partiel`, qui survit à une coupure du réseau comme à l'arrêt de Hoova ; la
/// suite est demandée par une requête partielle (`Range`), que Hugging Face accepte, même après sa redirection.
/// Le téléchargeur de swift-huggingface reprend aussi, mais il perd ce qu'il a reçu quand le transfert est coupé.
enum Download {
    /// Un fichier du modèle, tel que Hugging Face le liste.
    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64
    }

    private static let site = URL(string: "https://huggingface.co")!

    /// Les fichiers du modèle dont l'extension est dans `extensions`, à la version `revision`, rangés dans `folder`.
    /// `progress` va de 0 à 1.
    static func model(
        _ id: String, revision: String, into folder: URL, extensions: Set<String>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let files: [Entry]
        do {
            let (data, response) = try await URLSession.shared.data(
                from: site.appending(path: "api/models/\(id)/tree/\(revision)"))
            try check(response)
            files = try JSONDecoder().decode([Entry].self, from: data)
                .filter { $0.type == "file" && extensions.contains(($0.path as NSString).pathExtension) }
        } catch {
            throw readable(error)
        }
        let total = Double(max(files.reduce(0) { $0 + $1.size }, 1))
        var done: Int64 = 0
        for file in files {
            let destination = folder.appending(path: file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let before = done
            try await self.file(from: site.appending(path: "\(id)/resolve/\(revision)/\(file.path)"), to: destination) {
                progress(Double(before + $0) / total)
            }
            // Un fichier d'une autre taille que celle annoncée est abîmé : il repartira de zéro.
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
            guard size == file.size else {
                try? FileManager.default.removeItem(at: destination)
                throw Failure("Un fichier du modèle est arrivé abîmé. Réessaie : il sera téléchargé de nouveau.")
            }
            done += file.size
        }
        progress(1)
    }

    /// Un fichier, repris au bout de `<fichier>.partiel` s'il y en a un, puis renommé une fois complet.
    /// `progress` reçoit les octets déjà sur le disque, dix fois par seconde au plus.
    static func file(from url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { return }
        let partial = destination.appendingPathExtension("partiel")
        if !manager.fileExists(atPath: partial.path) { manager.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let offset = Int64(try handle.seekToEnd())
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        let receiver = Receiver(handle: handle, offset: offset, progress: progress)
        let session = URLSession(configuration: .default, delegate: receiver, delegateQueue: nil)
        let task = session.dataTask(with: request)
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    receiver.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw readable(error)
        }
        try handle.close()
        try manager.moveItem(at: partial, to: destination)
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw HTTPStatus(code: status) }
    }

    /// Une phrase claire à la place de l'erreur technique : c'est elle que montre l'accueil.
    private static func readable(_ error: Error) -> Error {
        switch error {
        case is CancellationError, is Failure: return error
        case let error as URLError where error.code == .cancelled: return CancellationError()
        case is URLError:
            return Failure("Le téléchargement s'est arrêté : la connexion à Internet est coupée. Réessaie : il reprendra là où il en était.")
        case let error as HTTPStatus:
            return Failure("Hugging Face ne donne pas le modèle pour l'instant (erreur \(error.code)). Réessaie plus tard.")
        case let error as CocoaError where error.code == .fileWriteOutOfSpace:
            return Failure("Le disque est plein. Libère de la place, puis réessaie : le téléchargement reprendra là où il en était.")
        default:
            return error
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String.LocalizationValue) { errorDescription = String(localized: message) }
    }

    private struct HTTPStatus: Error {
        let code: Int
    }

    /// Reçoit le fichier morceau par morceau et l'écrit au bout du fichier partiel. Son état n'est touché que sur la file
    /// de son délégué, une file série.
    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
        private let handle: FileHandle
        private let progress: @Sendable (Int64) -> Void
        private var written: Int64
        private var reported = ContinuousClock.now
        private var failure: Error?
        /// Le serveur répond qu'il n'y a plus rien après la partie déjà reçue : le fichier est complet.
        private var complete = false

        init(handle: FileHandle, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.handle = handle
            self.progress = progress
            written = offset
        }

        /// La redirection de Hugging Face vers son serveur de fichiers garde la demande de reprise.
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            var request = request
            if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
                request.setValue(range, forHTTPHeaderField: "Range")
            }
            completionHandler(request)
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 206:
                completionHandler(.allow)
            case 200:
                // Le serveur renvoie tout le fichier, sans tenir compte de la reprise : on repart de zéro.
                do {
                    try handle.truncate(atOffset: 0)
                    written = 0
                    completionHandler(.allow)
                } catch {
                    failure = error
                    completionHandler(.cancel)
                }
            case 416:
                complete = true
                completionHandler(.cancel)
            case let status:
                failure = HTTPStatus(code: status)
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                let now = ContinuousClock.now
                if now - reported >= .milliseconds(100) {
                    reported = now
                    progress(written)
                }
            } catch {
                failure = error
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            session.finishTasksAndInvalidate()
            if complete {
                continuation?.resume()
            } else if let error = failure ?? error {
                continuation?.resume(throwing: error)
            } else {
                progress(written)
                continuation?.resume()
            }
            continuation = nil
        }
    }
}
