import Foundation

/// The signed source-update feed request has no shared cookie/credential/cache
/// store. TLS trust uses the platform; all HTTP/proxy/client-certificate auth
/// is refused.
public enum AnonymousApplicationUpdateDownload {
    public static func bytes(from url: URL, maximumBytes: Int) async throws -> Data {
        guard maximumBytes > 0, isAnonymousHTTPS(url) else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let delegate = DownloadBoundary(maximumBytes: maximumBytes)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, isAnonymousHTTPS(finalURL),
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes else { throw URLError(.badServerResponse) }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    static func isAnonymousHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private final class DownloadBoundary: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let maximumBytes: Int
        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url.flatMap { isAnonymousHTTPS($0) ? request : nil })
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
}
