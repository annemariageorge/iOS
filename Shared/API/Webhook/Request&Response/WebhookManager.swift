import Foundation
import PromiseKit
import UserNotifications
import ObjectMapper

internal enum WebhookManagerError: Error {
    case noApi
    case unregisteredIdentifier
    case unexpectedType(given: String, desire: String)
    case unmappableValue
}

public class WebhookManager: NSObject {
    public static let URLSessionIdentifier = "hass.webhook_manager"

    private var backingBackgroundUrlSession: URLSession!
    internal var backgroundUrlSession: URLSession { return backingBackgroundUrlSession }
    internal let ephemeralUrlSession: URLSession
    private let backgroundEventGroup: DispatchGroup = DispatchGroup()
    private var pendingData: [Int: Data] = [:]
    private var resolverForIdentifier: [Int: Resolver<Void>] = [:]
    private var responseHandlers = [WebhookResponseIdentifier: WebhookResponseHandler.Type]()

    // MARK: - Lifecycle

    override internal init() {
        let configuration: URLSessionConfiguration

        if Current.isRunningTests {
            // we cannot mock http requests in a background session, so this code path has to differ
            configuration = .ephemeral
        } else {
            configuration = with(.background(withIdentifier: Self.URLSessionIdentifier)) {
                $0.sharedContainerIdentifier = Constants.AppGroupID
                $0.httpCookieStorage = nil
                $0.httpCookieAcceptPolicy = .never
                $0.httpShouldSetCookies = false
                $0.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            }
        }

        let queue = with(OperationQueue()) {
            $0.maxConcurrentOperationCount = 1
        }

        self.ephemeralUrlSession = URLSession(configuration: .ephemeral)

        super.init()

        self.backingBackgroundUrlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )

        register(responseHandler: WebhookResponseUnhandled.self, for: .unhandled)
    }

    internal func register(
        responseHandler: WebhookResponseHandler.Type,
        for identifier: WebhookResponseIdentifier
    ) {
        precondition(responseHandlers[identifier] == nil)
        responseHandlers[identifier] = responseHandler
    }

    public func handleBackground(for identifier: String, completionHandler: @escaping () -> Void) {
        Current.Log.notify("handleBackground started")
        // the pair of this enter is in urlSessionDidFinishEvents
        backgroundEventGroup.enter()

        backgroundEventGroup.notify(queue: DispatchQueue.main) {
            Current.Log.notify("final completion")
            completionHandler()
        }
    }

    // MARK: - Sending Ephemeral

    public func sendEphemeral(request: WebhookRequest) -> Promise<Void> {
        let promise: Promise<Any> = sendEphemeral(request: request)
        return promise.asVoid()
    }

    public func sendEphemeral<MappableResult: BaseMappable>(request: WebhookRequest) -> Promise<MappableResult> {
        let promise: Promise<Any> = sendEphemeral(request: request)
        return promise.map {
            if let result = Mapper<MappableResult>().map(JSONObject: $0) {
                return result
            } else {
                throw WebhookManagerError.unmappableValue
            }
        }
    }

    public func sendEphemeral<MappableResult: BaseMappable>(request: WebhookRequest) -> Promise<[MappableResult]> {
        let promise: Promise<Any> = sendEphemeral(request: request)
        return promise.map {
            if let result = Mapper<MappableResult>(shouldIncludeNilValues: false).mapArray(JSONObject: $0) {
                return result
            } else {
                throw WebhookManagerError.unmappableValue
            }
        }
    }

    public func sendEphemeral<ResponseType>(request: WebhookRequest) -> Promise<ResponseType> {
        attemptNetworking { [ephemeralUrlSession] in
            firstly {
                Self.urlRequest(for: request)
            }.then { urlRequest, data in
                ephemeralUrlSession.uploadTask(.promise, with: urlRequest, from: data)
            }
        }.then { data, response in
            Promise.value(data).webhookJson(
                on: DispatchQueue.global(qos: .utility),
                statusCode: (response as? HTTPURLResponse)?.statusCode
            )
        }.map { possible in
            if let value = possible as? ResponseType {
                return value
            } else {
                throw WebhookManagerError.unexpectedType(
                    given: String(describing: type(of: possible)),
                    desire: String(describing: ResponseType.self)
                )
            }
        }.tap { result in
            switch result {
            case .fulfilled(let response):
                Current.Log.info {
                    var log = "got successful response for \(request.type)"
                    if Current.isDebug {
                        log += ": \(response)"
                    }
                    return log
                }
            case .rejected(let error):
                Current.Log.error("got failure for \(request.type): \(error)")
            }
        }
    }

    // MARK: - Sending Persistent

    public func send(
        identifier: WebhookResponseIdentifier = .unhandled,
        request: WebhookRequest
    ) -> Promise<Void> {
        guard let handlerType = responseHandlers[identifier] else {
            Current.Log.error("no existing handler for \(identifier), not sending request")
            return .init(error: WebhookManagerError.unregisteredIdentifier)
        }

        let (promise, seal) = Promise<Void>.pending()

        firstly {
            Self.urlRequest(for: request)
        }.done { [backgroundUrlSession] urlRequest, data in
            let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let temporaryFile = temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("json")
            try data.write(to: temporaryFile, options: [])
            let task = backgroundUrlSession.uploadTask(with: urlRequest, fromFile: temporaryFile)

            let persisted = WebhookPersisted(request: request, identifier: identifier)
            task.webhookPersisted = persisted

            self.evaluateCancellable(
                by: task,
                type: handlerType,
                persisted: persisted,
                with: promise
            )
            self.resolverForIdentifier[task.taskIdentifier] = seal
            task.resume()

            try FileManager.default.removeItem(at: temporaryFile)
        }.catch { [weak self] error in
            self?.invoke(
                handler: handlerType,
                request: request,
                result: .init(error: error),
                resolver: seal
            )
        }

        return promise
    }

    // MARK: - Private

    private func evaluateCancellable(
        by newTask: URLSessionTask,
        type newType: WebhookResponseHandler.Type,
        persisted newPersisted: WebhookPersisted,
        with newPromise: Promise<Void>
    ) {
        backgroundUrlSession.getAllTasks { tasks in
            tasks.filter { thisTask in
                guard let (thisType, thisPersisted) = self.responseInfo(from: thisTask) else {
                    Current.Log.error("cancelling request without persistence info: \(thisTask)")
                    thisTask.cancel()
                    return false
                }

                if thisType == newType, thisTask != newTask {
                    return newType.shouldReplace(request: newPersisted.request, with: thisPersisted.request)
                } else {
                    return false
                }
            }.forEach { existingTask in
                if let existingResolver = self.resolverForIdentifier[existingTask.taskIdentifier] {
                    // connect the task we're about to cancel's promise to the replacement
                    newPromise.pipe { existingResolver.resolve($0) }
                }
                existingTask.cancel()
            }
        }
    }

    private static func urlRequest(for request: WebhookRequest) -> Promise<(URLRequest, Data)> {
        return Promise { seal in
            guard let api = Current.api() else {
                seal.reject(WebhookManagerError.noApi)
                return
            }

            var urlRequest = try URLRequest(
                url: api.connectionInfo.webhookURL,
                method: .post
            )
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let jsonObject = Mapper<WebhookRequest>(context: WebhookRequestContext.server).toJSON(request)
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])

            // httpBody is ignored by URLSession but is made available in tests
            urlRequest.httpBody = data

            seal.fulfill((urlRequest, data))
        }
    }

    private func handle(result: WebhookResponseHandlerResult) {
        if let notification = result.notification {
            UNUserNotificationCenter.current().add(notification) { error in
                if let error = error {
                    Current.Log.error("failed to add notification for result \(result): \(error)")
                }
            }
        }
    }

    private func responseInfo(from task: URLSessionTask) -> (WebhookResponseHandler.Type, WebhookPersisted)? {
        guard let persisted = task.webhookPersisted else {
            Current.Log.error("no persisted info for \(task) \(task.taskDescription ?? "(nil)")")
            return nil
        }

        guard let handlerType = responseHandlers[persisted.identifier] else {
            Current.Log.error("unknown response identifier \(persisted.identifier) for \(task)")
            return nil
        }

        return (handlerType, persisted)
    }
}

extension WebhookManager: URLSessionDelegate {
    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Current.Log.notify("event delivery ended")
        backgroundEventGroup.leave()
    }
}

extension WebhookManager: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        pendingData[dataTask.taskIdentifier, default: Data()].append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = pendingData[task.taskIdentifier]
        pendingData.removeValue(forKey: task.taskIdentifier)

        guard error?.isCancelled != true else {
            Current.Log.info("ignoring cancelled task")
            return
        }

        let result = Promise<Data?> { seal in
            if let error = error {
                seal.reject(error)
            } else {
                seal.fulfill(data)
            }
        }.webhookJson(
            on: DispatchQueue.global(qos: .utility),
            statusCode: (task.response as? HTTPURLResponse)?.statusCode
        )

        // dispatch
        if let (handlerType, persisted) = responseInfo(from: task) {
            // logging
            result.done { body in
                Current.Log.info {
                    if Current.isDebug {
                        return "got response type(\(handlerType)) request(\(persisted.request)) body(\(body))"
                    } else {
                        return "got response type(\(handlerType)) for \(persisted.identifier)"
                    }
                }
            }.catch { error in
                Current.Log.error("failed request for \(handlerType): \(error)")
            }

            invoke(
                handler: handlerType,
                request: persisted.request,
                result: result,
                resolver: resolverForIdentifier[task.taskIdentifier]
            )
        } else {
            Current.Log.notify("no handler for background task")
            Current.Log.error("couldn't find appropriate handler for \(task)")
        }
    }

    private func invoke(
        handler handlerType: WebhookResponseHandler.Type,
        request: WebhookRequest,
        result: Promise<Any>,
        resolver: Resolver<Void>?
    ) {
        guard let api = Current.api() else {
            Current.Log.error("no api")
            return
        }

        Current.Log.notify("starting \(request.type) (\(handlerType))")
        backgroundEventGroup.enter()

        let handler = handlerType.init(api: api)
        let handlerPromise = firstly {
            handler.handle(request: .value(request), result: result)
        }.done { [weak self] result in
            // keep the handler around until it finishes
            withExtendedLifetime(handler) {
                self?.handle(result: result)
            }
        }

        firstly {
            when(fulfilled: [handlerPromise.asVoid(), result.asVoid()])
        }.tap {
            resolver?.resolve($0)
        }.ensure { [backgroundEventGroup] in
            Current.Log.notify("finished \(request.type) \(handlerType)")
            backgroundEventGroup.leave()
        }.cauterize()
    }
}
