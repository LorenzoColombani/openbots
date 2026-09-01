import Foundation

public actor AsyncCallRecorder<Value: Sendable> {
    private var values: [Value] = []

    public init() {}

    public func record(_ value: Value) {
        values.append(value)
    }

    public func snapshot() -> [Value] {
        values
    }
}
