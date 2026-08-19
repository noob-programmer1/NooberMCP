// NetworkInterceptor.swift
// NooberProbe — URLProtocol subclass that intercepts all HTTP/HTTPS requests
//
// Registers itself via URLProtocol.registerClass() AND swizzles
// URLSessionConfiguration.default/.ephemeral to inject into protocolClasses.
// This catches requests from URLSession, Alamofire, and most networking libs.

import Foundation
import ObjectiveC
#if canImport(UIKit)
import UIKit
#endif

// MARK: - URLProtocol Interceptor

final class ProbeNetworkInterceptor: URLProtocol {

    private static let handledKey = "com.noober.probe.handled"
    private static let maxRequestBodyCapture = 64 * 1024   // 64 KB
    private static let maxResponseBodyCapture = 4 * 1024    // 4 KB preview

    private var internalSession: URLSession?
    private var internalTask: URLSessionDataTask?
    private var responseData = Data()
    private var responseObject: HTTPURLResponse?
    private var startTime: CFAbsoluteTime = 0

    // Lazy internal session configuration that excludes our interceptor to avoid loops
    private static let internalConfig: URLSessionConfiguration = {
        let config = URLSessionConfiguration.default
        config.protocolClasses = config.protocolClasses?.filter { $0 != ProbeNetworkInterceptor.self }
        return config
    }()

    // MARK: - URLProtocol Overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Only handle HTTP/HTTPS
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        // Skip if already handled
        if URLProtocol.property(forKey: handledKey, in: request) != nil {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Tag the request as handled
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)

        startTime = CFAbsoluteTimeGetCurrent()
        responseData = Data()

        // Check mock rules first — serve fake response without hitting network
        if let mock = ProbeMockRules.shared.findMatch(for: request) {
            serveMockResponse(mock)
            return
        }

        // Check intercept rules — block request and log it
        if let intercept = ProbeInterceptRules.shared.findMatch(for: request) {
            let error = NSError(domain: "NooberProbe", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Request intercepted by rule: \(intercept.name)"
            ])
            client?.urlProtocol(self, didFailWithError: error)
            recordRequest(error: error)
            return
        }

        // No mock or intercept match — forward to real network
        let session = URLSession(
            configuration: Self.internalConfig,
            delegate: self,
            delegateQueue: nil
        )
        internalSession = session

        let task = session.dataTask(with: mutableRequest as URLRequest)
        internalTask = task
        task.resume()
    }

    private func serveMockResponse(_ mock: ProbeMockRules.MockRule) {
        let url = request.url ?? URL(string: "https://mock")!
        let body = mock.responseBody.data(using: .utf8) ?? Data()
        let headers = mock.responseHeaders
        let httpResponse = HTTPURLResponse(url: url, statusCode: mock.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)

        // Record the mocked request
        responseData = body
        responseObject = httpResponse
        recordRequest(error: nil)
    }

    override func stopLoading() {
        internalTask?.cancel()
        internalTask = nil
        internalSession?.invalidateAndCancel()
        internalSession = nil
    }

    // MARK: - Registration

    static func install() {
        URLProtocol.registerClass(ProbeNetworkInterceptor.self)
        installSwizzle()
        probelog("Network interceptor installed")
    }

    // MARK: - Record Request

    private func recordRequest(error: Error?) {
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let url = request.url

        // Capture request body (up to limit)
        var requestBody: Data?
        if let body = request.httpBody {
            requestBody = body.count <= Self.maxRequestBodyCapture ? body : Data(body.prefix(Self.maxRequestBodyCapture))
        } else if let stream = request.httpBodyStream {
            requestBody = readStream(stream, maxBytes: Self.maxRequestBodyCapture)
        }

        // Capture response body preview (up to limit)
        let responseBodyPreview: Data?
        if responseData.isEmpty {
            responseBodyPreview = nil
        } else if responseData.count <= Self.maxResponseBodyCapture {
            responseBodyPreview = responseData
        } else {
            responseBodyPreview = Data(responseData.prefix(Self.maxResponseBodyCapture))
        }

        let entry = TransferableNetworkRequest(
            id: UUID(),
            timestamp: Date(),
            url: url?.absoluteString ?? "unknown",
            host: url?.host ?? "unknown",
            path: url?.path ?? "/",
            method: request.httpMethod ?? "GET",
            requestHeaders: request.allHTTPHeaderFields ?? [:],
            requestBody: requestBody,
            statusCode: responseObject?.statusCode,
            responseHeaders: (responseObject?.allHeaderFields as? [String: String]) ?? [:],
            responseBody: responseBodyPreview,
            duration: duration,
            errorDescription: error?.localizedDescription,
            mimeType: responseObject?.mimeType,
            isMocked: false,
            isIntercepted: false,
            isEnvironmentRewritten: false,
            originalURL: nil,
            screenName: ProbeState.shared.currentScreen,
            source: "URLSession"
        )

        ProbeState.shared.addRequest(entry)

        // Notify server for real-time streaming to macOS
        if let message = try? CompanionMessage(type: .eventHttpRequest, payload: entry) {
            DispatchQueue.main.async {
                ProbeServer.shared.send(message)
            }
        }
    }

    // MARK: - Stream Helper

    private func readStream(_ stream: InputStream, maxBytes: Int) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable && data.count < maxBytes {
            let bytesRead = stream.read(buffer, maxLength: min(bufferSize, maxBytes - data.count))
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else {
                break
            }
        }

        return data.isEmpty ? nil : data
    }
}

// MARK: - URLSessionDataDelegate

extension ProbeNetworkInterceptor: URLSessionDataDelegate {

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        responseObject = response as? HTTPURLResponse
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        recordRequest(error: error)

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Tag the redirect so we don't intercept it again
        let mutableRequest = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        client?.urlProtocol(self, wasRedirectedTo: mutableRequest as URLRequest, redirectResponse: response)
        completionHandler(mutableRequest as URLRequest)
    }
}

// MARK: - URLSessionConfiguration Swizzle

private var hasSwizzled = false

extension ProbeNetworkInterceptor {

    static func installSwizzle() {
        guard !hasSwizzled else { return }
        hasSwizzled = true

        // Swizzle .default
        if let originalDefault = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.`default`)),
           let swizzledDefault = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.probe_defaultConfig)) {
            method_exchangeImplementations(originalDefault, swizzledDefault)
        }

        // Swizzle .ephemeral
        if let originalEphemeral = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.ephemeral)),
           let swizzledEphemeral = class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.probe_ephemeralConfig)) {
            method_exchangeImplementations(originalEphemeral, swizzledEphemeral)
        }

        probelog("URLSessionConfiguration swizzle installed")
    }
}

extension URLSessionConfiguration {

    @objc dynamic class func probe_defaultConfig() -> URLSessionConfiguration {
        // After swizzle, this calls the original implementation
        let config = self.probe_defaultConfig()
        config.injectProbeInterceptor()
        return config
    }

    @objc dynamic class func probe_ephemeralConfig() -> URLSessionConfiguration {
        // After swizzle, this calls the original implementation
        let config = self.probe_ephemeralConfig()
        config.injectProbeInterceptor()
        return config
    }

    fileprivate func injectProbeInterceptor() {
        var protocols = self.protocolClasses ?? []
        if !protocols.contains(where: { $0 == ProbeNetworkInterceptor.self }) {
            protocols.insert(ProbeNetworkInterceptor.self, at: 0)
        }
        self.protocolClasses = protocols
    }
}

// MARK: - Logging

/// Writes a log message to stderr (or the original stderr fd if LogCapture has
/// redirected it). Tagged with [NooberProbe] so LogCapture can filter it out.
func probelog(_ message: String) {
    let line = "[NooberProbe] \(message)\n"
    let fd = ProbeLogCapture.probelogfd
    line.withCString { ptr in
        _ = write(fd, ptr, strlen(ptr))
    }
}
