import AppStoreConnect_Swift_SDK
import ArgumentParser
import Foundation
import SwiftTUI

// MARK: - xcc

@main struct xcc: AsyncParsableCommand {
    @Option var issuerID: String?
    @Option var privateKeyID: String?
    @Option var privateKey: String?

    @Option var product: String?
    @Option var workflow: String?
    @Option var reference: String?

    mutating func run() async throws {
        Termios.enterRawMode()
        defer { Termios.pop() }
        signal(SIGINT) { _ in
            Cursor.show()
            fflush(stdout)
            signal(SIGINT, SIG_DFL)
            raise(SIGINT)
        }

        let issuerID = issuerID ?? ProcessInfo.processInfo.environment["XCC_ISSUER_ID"]
        let privateKeyID = privateKeyID ?? ProcessInfo.processInfo.environment["XCC_PRIVATE_KEY_ID"]
        let privateKey = privateKey ?? ProcessInfo.processInfo.environment["XCC_PRIVATE_KEY"]

        guard let issuerID else { throw ValidationError("Missing Issuer ID. Create an API key at https://appstoreconnect.apple.com/access/api") }
        guard let privateKeyID else { throw ValidationError("Missing Private Key ID. Create an API key at https://appstoreconnect.apple.com/access/api") }
        guard var privateKey else { throw ValidationError("Missing Private Key. Create an API key at https://appstoreconnect.apple.com/access/api") }

        privateKey = privateKey.replacingOccurrences(of: "\n", with: "")
        if privateKey.hasPrefix("-----BEGIN PRIVATE KEY-----") {
            privateKey.removeFirst("-----BEGIN PRIVATE KEY-----".count)
        }
        if privateKey.hasSuffix("-----END PRIVATE KEY-----") {
            privateKey.removeLast("-----END PRIVATE KEY-----".count)
        }

        let configuration = try APIConfiguration(
            issuerID: issuerID,
            privateKeyID: privateKeyID,
            privateKey: privateKey
        )
        let provider = APIProvider(configuration: configuration)

        let bundleIDs = try await provider.request(
            APIEndpoint.v1.bundleIDs.get(parameters: .init(fieldsBundleIDs: [.identifier], limit: 200))
        ).data

        var products = try await provider.request(
            APIEndpoint.v1.ciProducts.get(parameters: .init(
                include: [.bundleID]
            ))
        ).data

        // Some products have the internal ASC bundleID ID
        // instead of the identifier for some reason
        for (index, product) in products.enumerated() {
            if let bundleID = bundleIDs.first(where: {
                $0.id == product.relationships?.bundleID?.data?.id
            })?.attributes?.identifier {
                products[index].relationships?.bundleID?.data?.id = bundleID
            }
        }

        let selectedProduct = if let product {
            products.first(where: { $0.attributes?.name == product })
        } else {
            chooseFromList(products, prompt: "Select a product:")
        }
        guard let selectedProduct else {
            throw Error.couldNotFindProduct(availableProducts: products)
        }

        let workflows = try await provider.request(
            APIEndpoint.v1.ciProducts.id(selectedProduct.id).workflows.get()
        ).data

        let selectedWorkflow = if let workflow {
            workflows.first(where: { $0.attributes?.name == workflow })
        } else {
            chooseFromList(workflows, prompt: "Select a workflow:")
        }
        guard let selectedWorkflow else {
            throw Error.couldNotFindWorkflow(availableWorkflows: workflows)
        }

        let repository = try await provider.request(
            APIEndpoint.v1.ciWorkflows.id(selectedWorkflow.id).repository.get()
        ).data

        let gitReferences = try await provider.request(
            APIEndpoint.v1.scmRepositories.id(repository.id).gitReferences.get()
        ).data

        let selectedGitReference = if let reference {
            gitReferences.first(where: { $0.attributes?.name == reference })
        } else {
            chooseFromList(gitReferences, prompt: "Select a reference:")
        }
        guard let selectedGitReference else {
            throw Error.couldNotFindReference(availableReferences: gitReferences)
        }

        _ = try? await provider.request(APIEndpoint.v1.ciBuildRuns.post(.init(
            data: .init(
                type: .ciBuildRuns,
                relationships: .init(
                    workflow: .init(data: .init(
                        type: .ciWorkflows,
                        id: selectedWorkflow.id
                    )),
                    sourceBranchOrTag: .init(data: .init(
                        type: .scmGitReferences,
                        id: selectedGitReference.id
                    ))
                )
            )
        ))).data

        print("✓ ".brightGreen.bold + "Build started")
    }
}

// MARK: xcc.Error

extension xcc {
    enum Error: LocalizedError {
        case missingIssuerID
        case missingPrivateKeyID
        case missingPrivateKey

        case couldNotFindProduct(availableProducts: [CiProduct])
        case couldNotFindWorkflow(availableWorkflows: [CiWorkflow])
        case couldNotFindReference(availableReferences: [ScmGitReference])

        // MARK: Internal

        var errorDescription: String? {
            switch self {
            case .missingIssuerID: """
                Missing Issuer ID. Create an API key at https://appstoreconnect.apple.com/access/api and specify an Issuer ID using one of the following:
                - Pass it to xcc as a flag (--issuer-id <issuer-id>)
                - Set an environment variable (XCC_ISSUER_ID=<issuer-id>)
                """

            case .missingPrivateKeyID: """
                Missing Private Key ID. Create an API key at https://appstoreconnect.apple.com/access/api and specify a Private Key ID using one of the following:
                - Pass it to xcc as a flag (--private-key-id <private-key-id>)
                - Set an environment variable (XCC_PRIVATE_KEY_ID=<private-key-id>)
                """

            case .missingPrivateKey: """
                Missing Private Key. Create an API key at https://appstoreconnect.apple.com/access/api and specify a Private Key using one of the following:
                - Pass it to xcc as a flag (--private-key <private-key>)
                - Set an environment variable (XCC_PRIVATE_KEY=<private-key>)
                """

            case let .couldNotFindProduct(products): """
                Could not find product with specified name. Available products:
                \(products.compactMap(\.attributes?.name).map { "- \($0)" }.joined(separator: "\n"))
                """

            case let .couldNotFindWorkflow(workflows): """
                Could not find workflow with specified name. Available workflows:
                \(workflows.compactMap(\.attributes?.name).map { "- \($0)" }.joined(separator: "\n"))
                """

            case let .couldNotFindReference(references): """
                Could not find reference with specified name. Available references:
                \(references.compactMap(\.attributes?.name).map { "- \($0)" }.joined(separator: "\n"))
                """
            }
        }
    }
}

// MARK: - CiProduct + CustomStringConvertible

extension CiProduct: CustomStringConvertible {
    public var description: String {
        let name = attributes?.name ?? "Unknown"
        let bundleID = relationships?.bundleID?.data
        return "\(name) \((bundleID.map { "(\($0.id))" } ?? "").faint)"
    }
}

// MARK: - CiWorkflow + CustomStringConvertible

extension CiWorkflow: CustomStringConvertible {
    public var description: String {
        attributes?.name ?? "Unknown"
    }
}

// MARK: - ScmGitReference + CustomStringConvertible

extension ScmGitReference: CustomStringConvertible {
    public var description: String {
        switch attributes?.kind {
        case .branch:
            "(branch) ".faint + (attributes?.name ?? "")
        case .tag:
            "   (tag) ".faint + (attributes?.name ?? "")
        case nil:
            attributes?.name ?? ""
        }
    }
}
