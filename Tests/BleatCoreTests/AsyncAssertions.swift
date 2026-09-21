import Testing

func assertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await expression()
        Issue.record(
            "Expected expression to throw", sourceLocation: sourceLocation)
    } catch {
        errorHandler(error)
    }
}
