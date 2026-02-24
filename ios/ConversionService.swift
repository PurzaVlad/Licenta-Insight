import Foundation
import React

enum ConversionPrivacyPolicy {
    static let uploadedDataDescription = "Only the selected file bytes plus extension metadata are uploaded when server conversion is required."
    static let serverRetentionDescription = "Server retention target: immediate delete after conversion response."
    static let authScopeDescription = "Authorization token is scoped to conversion endpoints."
}

@objc(ConversionService)
class ConversionService: NSObject {
    private let maxRetries = 3
    private let retryDelays: [TimeInterval] = [1, 2, 4]
    private let requestTimeout: TimeInterval = 120

    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func healthCheck(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let config = try ConversionConfig.load()
                let url = config.baseURL.appendingPathComponent("health")
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = self.requestTimeout

                let session = self.makeSession()
                let task = session.dataTask(with: request) { data, response, error in
                    guard error == nil, let http = response as? HTTPURLResponse else {
                        DispatchQueue.main.async { resolve(false) }
                        return
                    }
                    guard http.statusCode == 200 else {
                        DispatchQueue.main.async { resolve(false) }
                        return
                    }
                    let body = String(data: data ?? Data(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    DispatchQueue.main.async { resolve(body == "ok") }
                }
                task.resume()
            } catch {
                DispatchQueue.main.async { resolve(false) }
            }
        }
    }

    @objc func convertFile(_ inputPath: String,
                           targetExt: String,
                           documentId: String?,
                           resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let config = try ConversionConfig.load()
                self.performConvert(inputPath: inputPath,
                                    targetExt: targetExt,
                                    documentId: documentId,
                                    config: config,
                                    retryCount: 0,
                                    resolve: resolve,
                                    reject: reject)
            } catch {
                self.reject(error, rejecter: reject)
            }
        }
    }

    private func performConvert(inputPath: String,
                                targetExt: String,
                                documentId: String?,
                                config: ConversionConfig,
                                retryCount: Int,
                                resolve: @escaping RCTPromiseResolveBlock,
                                reject: @escaping RCTPromiseRejectBlock) {
        do {
            let fileURL = try resolveFileURL(inputPath: inputPath)
            let inputFilename = fileURL.lastPathComponent
            let inputExt = fileURL.pathExtension
            let target = targetExt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if target.isEmpty {
                throw ConversionServiceError.invalidRequest(reason: "Missing target extension")
            }

            var components = URLComponents(url: config.baseURL.appendingPathComponent("convert"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "target", value: target)]
            guard let url = components?.url else {
                throw ConversionServiceError.invalidRequest(reason: "Invalid convert URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = requestTimeout
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Send only the extension — the actual filename is private to the user's device.
            // The server uses X-File-Ext for format detection; the name itself is never needed.
            request.setValue(inputExt, forHTTPHeaderField: "X-File-Ext")

            guard let stream = InputStream(url: fileURL) else {
                throw ConversionServiceError.invalidRequest(reason: "Unable to open file stream")
            }
            request.httpBodyStream = stream

            if let fileSize = fileSizeBytes(url: fileURL) {
                request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
            }

            let session = makeSession()
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    self.reject(ConversionServiceError.networkError(underlying: error), rejecter: reject)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    self.reject(ConversionServiceError.invalidResponse, rejecter: reject)
                    return
                }

                let status = http.statusCode
                if status == 200 {
                    guard let body = data else {
                        self.reject(ConversionServiceError.emptyResponse, rejecter: reject)
                        return
                    }
                    let outputFilename = self.resolveOutputFilename(
                        from: http.allHeaderFields,
                        fallbackBase: fileURL.deletingPathExtension().lastPathComponent,
                        targetExt: target
                    )
                    do {
                        let outputURL = try self.writeOutputFile(
                            data: body,
                            filename: outputFilename,
                            documentId: documentId,
                            targetExt: target
                        )
                        DispatchQueue.main.async {
                            resolve([
                                "outputPath": outputURL.path,
                                "outputFilename": outputURL.lastPathComponent
                            ])
                        }
                    } catch {
                        self.reject(error, rejecter: reject)
                    }
                    return
                }

                let errorCode = String(data: data ?? Data(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() ?? "unknown_error"

                if status == 429, retryCount < self.maxRetries {
                    let delay = self.retryDelays[retryCount]
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                        self.performConvert(inputPath: inputPath,
                                            targetExt: targetExt,
                                            documentId: documentId,
                                            config: config,
                                            retryCount: retryCount + 1,
                                            resolve: resolve,
                                            reject: reject)
                    }
                    return
                }

                self.reject(ConversionServiceError.httpError(status: status, errorCode: errorCode), rejecter: reject)
            }
            task.resume()
        } catch {
            self.reject(error, rejecter: reject)
        }
    }

    private func resolveFileURL(inputPath: String) throws -> URL {
        let url: URL
        if inputPath.hasPrefix("file://"), let fileURL = URL(string: inputPath) {
            url = fileURL
        } else {
            url = URL(fileURLWithPath: inputPath)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionServiceError.invalidRequest(reason: "Input file not found")
        }
        return url
    }

    private func resolveOutputFilename(from headers: [AnyHashable: Any], fallbackBase: String, targetExt: String) -> String {
        let headerValue = headers.first { key, _ in
            String(describing: key).lowercased() == "content-disposition"
        }?.value as? String

        if let headerValue, let parsed = ContentDisposition.filename(from: headerValue) {
            return parsed
        }

        let safeBase = fallbackBase.isEmpty ? "converted" : fallbackBase
        let safeExt = targetExt.isEmpty ? "bin" : targetExt
        return "\(safeBase).\(safeExt)"
    }

    private func writeOutputFile(data: Data, filename: String, documentId: String?, targetExt: String) throws -> URL {
        let _ = filename
        if let documentId, let uuid = UUID(uuidString: documentId) {
            do {
                return try FileStorageService.shared.writeConvertedOutput(data, documentId: uuid, targetExtension: targetExt)
            } catch {
                throw ConversionServiceError.writeFailed(reason: "Failed to write converted output")
            }
        }

        let fallbackName = "converted_\(UUID().uuidString.lowercased())_\(targetExt).\(targetExt)"
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let convertedDir = cachesDir.appendingPathComponent("Converted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: convertedDir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
            try (convertedDir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            let outputURL = convertedDir.appendingPathComponent(fallbackName)
            try data.write(to: outputURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try (outputURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
            return outputURL
        } catch {
            throw ConversionServiceError.writeFailed(reason: "Failed to write output file")
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }

    private func fileSizeBytes(url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return values.fileSize.map { Int64($0) }
        } catch {
            return nil
        }
    }

    private func reject(_ error: Error, rejecter: @escaping RCTPromiseRejectBlock) {
        let conversionError = error as? ConversionServiceError
        let code = conversionError?.errorCode ?? "conversion_failed"
        let message = conversionError?.message ?? "Conversion failed"
        let nsError = conversionError?.asNSError() ?? error as NSError
        DispatchQueue.main.async {
            rejecter(code, message, nsError)
        }
    }
}

struct ConversionConfig {
    let baseURL: URL
    let apiKey: String

    static func load() throws -> ConversionConfig {
        guard let baseURLString = Bundle.main.object(forInfoDictionaryKey: "CONVERT_BASE_URL") as? String,
              !baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionServiceError.missingConfig(key: "CONVERT_BASE_URL")
        }
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "CONVERT_API_KEY") as? String,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionServiceError.missingConfig(key: "CONVERT_API_KEY")
        }

        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let baseURL = URL(string: normalized) else {
            throw ConversionServiceError.invalidRequest(reason: "Invalid CONVERT_BASE_URL")
        }
        let scheme = (baseURL.scheme ?? "").lowercased()
        if scheme != "https" {
#if DEBUG
            let allowInsecure = (Bundle.main.object(forInfoDictionaryKey: "CONVERT_ALLOW_INSECURE_HTTP_DEBUG") as? Bool) ?? false
            guard allowInsecure else {
                assertionFailure("CONVERT_BASE_URL must be HTTPS. Set CONVERT_ALLOW_INSECURE_HTTP_DEBUG=true only for local debug.")
                throw ConversionServiceError.invalidRequest(reason: "CONVERT_BASE_URL must use https")
            }
#else
            throw ConversionServiceError.invalidRequest(reason: "CONVERT_BASE_URL must use https")
#endif
        }
        return ConversionConfig(baseURL: baseURL, apiKey: apiKey)
    }
}

enum ConversionServiceError: Error {
    case missingConfig(key: String)
    case invalidRequest(reason: String)
    case invalidResponse
    case networkError(underlying: Error)
    case emptyResponse
    case httpError(status: Int, errorCode: String)
    case writeFailed(reason: String)

    var errorCode: String? {
        switch self {
        case .missingConfig:
            return "missing_config"
        case .invalidRequest:
            return "invalid_request"
        case .invalidResponse:
            return "invalid_response"
        case .networkError:
            return "network_error"
        case .emptyResponse:
            return "empty_response"
        case .httpError(_, let errorCode):
            return errorCode
        case .writeFailed:
            return "write_failed"
        }
    }

    var httpStatus: Int? {
        switch self {
        case .httpError(let status, _):
            return status
        default:
            return nil
        }
    }

    var message: String {
        switch self {
        case .missingConfig(let key):
            return "Missing configuration: \(key)"
        case .invalidRequest(let reason):
            return reason
        case .invalidResponse:
            return "Invalid server response"
        case .networkError(let underlying):
            return underlying.localizedDescription
        case .emptyResponse:
            return "Empty response"
        case .httpError(let status, let errorCode):
            return "HTTP \(status): \(errorCode)"
        case .writeFailed(let reason):
            return reason
        }
    }

    func asNSError() -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: message
        ]
        if let httpStatus {
            userInfo["httpStatus"] = httpStatus
        }
        if let errorCode {
            userInfo["errorCode"] = errorCode
        }
        return NSError(domain: "ConversionService", code: httpStatus ?? -1, userInfo: userInfo)
    }
}

struct ContentDisposition {
    static func filename(from header: String) -> String? {
        if let quoted = match(header: header, pattern: "filename\\s*=\\s*\"([^\"]+)\"") {
            return sanitize(filename: quoted)
        }
        if let unquoted = match(header: header, pattern: "filename\\s*=\\s*([^;]+)") {
            return sanitize(filename: unquoted)
        }
        return nil
    }

    private static func match(header: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = regex.firstMatch(in: header, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let valueRange = Range(match.range(at: 1), in: header) else {
            return nil
        }
        return String(header[valueRange])
    }

    private static func sanitize(filename: String) -> String? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let cleaned = URL(fileURLWithPath: decoded).lastPathComponent
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return nil
        }
        return cleaned
    }
}
