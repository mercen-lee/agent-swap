import Foundation
import Testing
@testable import AgentSwapCore

@Suite("Provider HTTP authentication boundaries")
struct ProviderHTTPErrorTests {
    @Test("Forbidden responses preserve authentication instead of requesting a refresh", arguments: [
        #"{"error":{"type":"permission_error","message":"fixture-private-permission"}}"#,
        #"{"error":{"code":"insufficient_scope","message":"fixture-private-scope"}}"#,
        "fixture-private-gateway-response"
    ])
    func forbiddenIsNotAnExpiredGrant(_ body: String) {
        do {
            _ = try ProviderHTTP.checked(.init(data: Data(body.utf8), statusCode: 403))
            Issue.record("Forbidden response must fail the usage request")
        } catch let error as AgentSwapError {
            guard case .network = error else {
                Issue.record("Permission failures must not trigger OAuth refresh or needsLogin")
                return
            }
            #expect(error.localizedDescription.contains("HTTP 403"))
            #expect(!error.localizedDescription.contains("fixture-private"))
        } catch {
            Issue.record("Expected a redacted provider error")
        }
    }

    @Test("Expired refresh grants are recognized in both provider error formats", arguments: [
        #"{"error":"invalid_grant","error_description":"fixture-private-detail"}"#,
        #"{"error":{"code":"refresh_token_reused","message":"fixture-private-detail"}}"#,
        #"{"error":{"type":"invalid_grant","message":"fixture-private-detail"}}"#
    ])
    func invalidGrantRequiresLogin(_ body: String) {
        do {
            _ = try ProviderHTTP.checked(.init(data: Data(body.utf8), statusCode: 400))
            Issue.record("An expired grant must fail")
        } catch let error as AgentSwapError {
            guard case .authentication = error else {
                Issue.record("A rejected refresh grant requires a new login")
                return
            }
            #expect(!error.localizedDescription.contains("fixture-private"))
        } catch {
            Issue.record("Expected a redacted provider error")
        }
    }

    @Test("Unauthorized access still permits the engine's single refresh retry")
    func unauthorizedIsAuthentication() {
        #expect(throws: AgentSwapError.authentication("인증이 만료되었거나 유효하지 않습니다. 다시 로그인하세요.")) {
            try ProviderHTTP.checked(.init(data: Data("fixture-private-token".utf8), statusCode: 401))
        }
    }
}
