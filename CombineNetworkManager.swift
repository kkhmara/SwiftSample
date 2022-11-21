import Combine
import Foundation

// MARK: - NetworkManager
protocol CombineNetworkManagerProtocol {
    func makeRequest<ResultType: Decodable>(method: HTTPMethod, endpoint: Endpoint, body: HTTPBody?,
                                            headers: HTTPHeaders, authMode: NetworkAuthMode)
    -> AnyPublisher<ResultType, NetworkRequestError>
}

extension CombineNetworkManagerProtocol {
    func makeRequest<ResultType: Decodable>(method: HTTPMethod, endpoint: APIEndpoint, body: HTTPBody? = nil,
                                            authMode: NetworkAuthMode = .mandatory)
    -> AnyPublisher<ResultType, NetworkRequestError> {
        makeRequest(method: method, endpoint: endpoint, body: body, headers: [:], authMode: authMode)
    }

    func makeRequest<ResultType: Decodable>(method: HTTPMethod, endpoint: SharedStoreEndpoint, body: HTTPBody? = nil,
                                            authMode: NetworkAuthMode = .mandatory)
    -> AnyPublisher<ResultType, NetworkRequestError> {
        makeRequest(method: method, endpoint: endpoint, body: body, headers: [:], authMode: authMode)
    }
}

final class CombineNetworkManager: CombineNetworkManagerProtocol {
    private enum Constants {
        static let retryCount = 1
    }

    private static var jsonDecoder: JSONDecoder = {
        let jsonDecoder = JSONDecoder()
        // TODO: - We should modify API to only return correct iso8601 format
        // jsonDecoder.dateDecodingStrategy = .iso8601
        jsonDecoder.dateDecodingStrategy = .defaultDateDecodingStrategy
        return jsonDecoder
    }()

    private var tokenManager: TokenManager

    private static let session = URLSession.shared

    init(tokenManager: TokenManager? = nil) {
        self.tokenManager = tokenManager ?? DepContainer.shared.tokenManager
    }

    private func httpError(_ statusCode: Int, message: String? = nil) -> NetworkRequestError {
        switch statusCode {
        case 400:
            return .badRequest(message)
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(message)
        case 404:
            return .notFound
        case 402, 405...499:
            return .error4xx(statusCode)
        case 500:
            return .serverError(message)
        case 501...599:
            return .error5xx(statusCode)
        default:
            return .unknownError
        }
    }

    private static func handleError(_ error: Error) -> NetworkRequestError {
        switch error {
        case let error as DecodingError:
            return .decodingError(error)
        case let urlError as URLError:
            return .urlSessionFailed(urlError)
        case let error as NetworkRequestError:
            return error
        default:
            return .unknownError
        }
    }

    private func parseErrorResponseIfNeeded(data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, !(200..<300 ~= response.statusCode) else {
            return
        }

        if let oldAPIError = try? Self.jsonDecoder.decode(OldAPIError.self, from: data) {
            throw httpError(response.statusCode, message: oldAPIError.errorMessage)
        }

        throw httpError(response.statusCode)
    }

    private func applyHeaders(withMode: NetworkAuthMode, method: HTTPMethod) -> HTTPHeaders {
        var defaultHeaders = HTTPHeaders.defaultUserAgent
        defaultHeaders["Content-Type"] = method == .get ?
            HTTPHeaders.urlEncodedContentType : HTTPHeaders.jsonContentType
        let token = tokenManager.authToken
        switch (withMode, token != nil) {
        case (.skip, _), (.mandatory, false):
            break
        case (.mandatory, true):
            guard let thisToken = token else {
                fatalError("We can't be here")
            }
            defaultHeaders["Authorization"] = "Bearer \(thisToken)"
        }
        return defaultHeaders
    }

    private func refreshToken(error: Error) -> AnyPublisher<AuthToken, Error> {
        let body = ["refreshToken": tokenManager.refreshToken ?? ""] as JSONParameters
        return makeRequest(method: .post, endpoint: .refreshTokenV2(), body: body, authMode: .skip)
            .handleEvents(receiveOutput: { [weak self] response in
                self?.tokenManager.authToken = response.authToken
            })
            .mapError { $0 as Error }
            .eraseToAnyPublisher()
    }

    private func makeRequestRaw(method: HTTPMethod, endpoint: Endpoint, body: HTTPBody?,
                                headers: [String: String], authMode: NetworkAuthMode)
    -> AnyPublisher<Data, Error> {
        let combinedHeaders = applyHeaders(withMode: authMode, method: method)
            .merging(headers, uniquingKeysWith: { lhs, _ in lhs })
        var urlRequest = endpoint.asURLRequest()
        urlRequest.httpMethod = method.rawValue
        urlRequest.httpBody = body?.httpData()
        urlRequest.allHTTPHeaderFields = combinedHeaders

        return Self.session.dataTaskPublisher(for: urlRequest)
            .subscribe(on: DispatchQueue.global())
            .receive(on: DispatchQueue.main)
            .tryMap { [weak self] data, response in
                try self?.parseErrorResponseIfNeeded(data: data, response: response)
                return data
            }
            .eraseToAnyPublisher()
    }

    func makeRequest<ResultType: Decodable>(method: HTTPMethod, endpoint: Endpoint, body: HTTPBody?,
                                            headers: HTTPHeaders, authMode: NetworkAuthMode)
    -> AnyPublisher<ResultType, NetworkRequestError> {
        makeRequestRaw(method: method, endpoint: endpoint, body: body, headers: headers,
                       authMode: authMode)
            .tryCatch { [unowned self] error -> AnyPublisher<Data, Error> in
                // try to refresh the token and repeat request
                guard case NetworkRequestError.unauthorized = error else {
                    throw error
                }
                let refreshToken = self.refreshToken(error: error)
                let repeatRequest = self.makeRequestRaw(method: method, endpoint: endpoint, body: body,
                                                        headers: headers, authMode: authMode)
                return refreshToken
                    .flatMap { _ in repeatRequest }
                    .eraseToAnyPublisher()
            }
            .tryMap { data in
                let parsedResult: ResultType
                if endpoint.version.isV2 || endpoint is SharedStoreEndpoint {
                    parsedResult = try Self.jsonDecoder.decode(ResultType.self, from: data)
                } else {
                    parsedResult = try Self.jsonDecoder.decode(APIResult<ResultType>.self, from: data).result
                }
                return parsedResult
            }
            .mapError { error in
                Self.handleError(error)
            }
            .retry(times: Constants.retryCount, if: { error in
                if case NetworkRequestError.unauthorized = error {
                    return true
                }
                return false
            })
            .eraseToAnyPublisher()
    }
}
