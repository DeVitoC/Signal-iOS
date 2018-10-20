//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation

public extension Error {
    var isRetryable: Bool {
        return (self as NSError).isRetryable
    }
}

@objc(SSKMessageSenderJobQueue)
public class MessageSenderJobQueue: NSObject, JobQueue {

    // MARK: 

    @objc(addMessage:transaction:)
    public func add(message: TSOutgoingMessage, transaction: YapDatabaseReadWriteTransaction) {
        self.add(message: message, removeMessageAfterSending: false, transaction: transaction)
    }

    @objc(addMediaMessage:dataSource:contentType:sourceFilename:isTemporaryAttachment:)
    public func add(mediaMessage: TSOutgoingMessage, dataSource: DataSource, contentType: String, sourceFilename: String?, isTemporaryAttachment: Bool) {
        OutgoingMessagePreparer.prepareAttachment(with: dataSource,
                                                       contentType: contentType,
                                                       sourceFilename: sourceFilename,
                                                       in: mediaMessage) { error in
                                                        if let error = error {
                                                            self.dbConnection.readWrite { transaction in
                                                                mediaMessage.update(sendingError: error, transaction: transaction)
                                                            }
                                                        } else {
                                                            self.dbConnection.readWrite { transaction in
                                                                self.add(message: mediaMessage, removeMessageAfterSending: isTemporaryAttachment, transaction: transaction)
                                                            }
                                                        }
        }
    }

    private func add(message: TSOutgoingMessage, removeMessageAfterSending: Bool, transaction: YapDatabaseReadWriteTransaction) {
        let jobRecord: SSKMessageSenderJobRecord
        do {
            jobRecord = try SSKMessageSenderJobRecord(message: message, removeMessageAfterSending: false, label: self.jobRecordLabel)
        } catch {
            owsFailDebug("failed to build job: \(error)")
            return
        }
        self.add(jobRecord: jobRecord, transaction: transaction)
    }

    // MARK: JobQueue

    public typealias DurableOperationType = MessageSenderOperation
    public static let jobRecordLabel: String = "MessageSender"
    public static let maxRetries: UInt = 10

    public var jobRecordLabel: String {
        return type(of: self).jobRecordLabel
    }

    @objc
    public func setup() {
        defaultSetup()
    }

    @objc
    public var isReady: Bool = false {
        didSet {
            if isReady {
                DispatchQueue.global().async {
                    self.workStep()
                }
            }
        }
    }

    public func didMarkAsReady(oldJobRecord: SSKMessageSenderJobRecord, transaction: YapDatabaseReadWriteTransaction) {
        if let messageId = oldJobRecord.messageId, let message = TSOutgoingMessage.fetch(uniqueId: messageId, transaction: transaction) {
            message.updateWithMarkingAllUnsentRecipientsAsSending(with: transaction)
        }
    }

    public func buildOperation(jobRecord: SSKMessageSenderJobRecord, transaction: YapDatabaseReadTransaction) throws -> MessageSenderOperation {
        let message: TSOutgoingMessage
        if let invisibleMessage = jobRecord.invisibleMessage {
            message = invisibleMessage
        } else if let messageId = jobRecord.messageId, let fetchedMessage = TSOutgoingMessage.fetch(uniqueId: messageId, transaction: transaction) {
            message = fetchedMessage
        } else {
            assert(jobRecord.messageId != nil)
            throw JobError.obsolete(description: "message no longer exists")
        }

        return MessageSenderOperation(message: message, jobRecord: jobRecord)
    }

    var senderQueues: [String: OperationQueue] = [:]
    let defaultQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.name = "DefaultSendingQueue"
        operationQueue.maxConcurrentOperationCount = 1

        return operationQueue
    }()

    public func operationQueue(jobRecord: SSKMessageSenderJobRecord) -> OperationQueue {
        guard let threadId = jobRecord.threadId else {
            return defaultQueue
        }

        guard let existingQueue = senderQueues[threadId] else {
            let operationQueue = OperationQueue()
            operationQueue.name = "SendingQueue:\(threadId)"
            operationQueue.maxConcurrentOperationCount = 1

            senderQueues[threadId] = operationQueue

            return operationQueue
        }

        return existingQueue
    }
}

public class MessageSenderOperation: OWSOperation, DurableOperation {

    // MARK: DurableOperation

    public let jobRecord: SSKMessageSenderJobRecord

    weak public var durableOperationDelegate: MessageSenderJobQueue?

    public var operation: Operation {
        return self
    }

    // MARK: Init

    let message: TSOutgoingMessage

    init(message: TSOutgoingMessage, jobRecord: SSKMessageSenderJobRecord) {
        self.message = message
        self.jobRecord = jobRecord
        super.init()
    }

    // MARK: Dependencies

    var messageSender: MessageSender {
        return SSKEnvironment.shared.messageSender
    }

    var dbConnection: YapDatabaseConnection {
        return SSKEnvironment.shared.primaryStorage.dbReadWriteConnection
    }

    // MARK: OWSOperation

    override public func run() {
        self.messageSender.send(message, success: reportSuccess, failure: reportError)
    }

    override public func didSucceed() {
        self.dbConnection.readWrite { transaction in
            self.durableOperationDelegate?.durableOperationDidSucceed(self, transaction: transaction)
            if self.jobRecord.removeMessageAfterSending {
                self.message.remove(with: transaction)
            }
        }
    }

    override public func didReportError(_ error: Error) {
        Logger.debug("remainingRetries: \(self.remainingRetries)")

        self.dbConnection.readWrite { transaction in
            self.durableOperationDelegate?.durableOperation(self, didReportError: error, transaction: transaction)
        }
    }

    override public func retryDelay() -> dispatch_time_t {
        guard !CurrentAppContext().isRunningTests else {
            return 0
        }

        // Arbitrary backoff factor...
        // 10 failures, wait ~1min
        let backoffFactor = 1.9
        let maxBackoff = kHourInterval

        let seconds = 0.1 * min(maxBackoff, pow(backoffFactor, Double(self.jobRecord.failureCount)))
        return UInt64(seconds) * NSEC_PER_SEC
    }

    override public func didFail(error: Error) {
        self.dbConnection.readWrite { transaction in
            self.durableOperationDelegate?.durableOperation(self, didFailWithError: error, transaction: transaction)

            self.message.update(sendingError: error, transaction: transaction)
            if self.jobRecord.removeMessageAfterSending {
                self.message.remove(with: transaction)
            }
        }
    }
}
