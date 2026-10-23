import Foundation
import AgentSwapVaultProtocol

@main
struct AgentSwapVaultServiceMain {
    static func main() {
        VaultXPCService(applicationRequirement: AgentSwapVaultWire.applicationRequirement).run()
    }
}
