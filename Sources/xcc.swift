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
    @Option var pullRequestID: Int?

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

        guard let issuerID else { throw ValidationError("Missing Issuer ID. Create an API key with the \"Developer\" role at https://appstoreconnect.apple.com/access/api") }
        guard let privateKeyID else { throw ValidationError("Missing Private Key ID. Create an API key with the \"Developer\" role at https://appstoreconnect.apple.com/access/api") }
        guard var privateKey else { throw ValidationError("Missing Private Key. Create an API key with the \"Developer\" role at https://appstoreconnect.apple.com/access/api") }

        guard reference == nil || pullRequestID == nil else {
            throw Error.multipleSourceTypes
        }

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

        ActivityIndicator.start()
        let bundleIDs = try await provider.requestAll(
            APIEndpoint.v1.bundleIDs.get(parameters: .init(fieldsBundleIDs: [.identifier], limit: 200))
        ).flatMap(\.data)

        var products = try await provider.requestAll(
            APIEndpoint.v1.ciProducts.get(parameters: .init(
                include: [.bundleID]
            ))
        ).flatMap(\.data)
        ActivityIndicator.stop()

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
            CommandLine.chooseFromList(products, prompt: "Select a product:")
        }
        guard let selectedProduct else {
            throw Error.couldNotFindProduct(availableProducts: products)
        }

        ActivityIndicator.start()
        let workflows = try await provider.requestAll(
            APIEndpoint.v1.ciProducts.id(selectedProduct.id).workflows.get()
        ).flatMap(\.data)
        ActivityIndicator.stop()

        let selectedWorkflow = if let workflow {
            workflows.first(where: { $0.attributes?.name == workflow })
        } else {
            CommandLine.chooseFromList(workflows, prompt: "Select a workflow:")
        }
        guard let selectedWorkflow else {
            throw Error.couldNotFindWorkflow(availableWorkflows: workflows)
        }

        let selectedSourceType = if reference != nil {
            SourceType.reference
        } else if pullRequestID != nil {
            SourceType.pullRequest
        } else {
            CommandLine.chooseFromList(SourceType.allCases, prompt: "Select a source type:")
        }

        ActivityIndicator.start()

        let repository = try await provider.request(
            APIEndpoint.v1.ciWorkflows.id(selectedWorkflow.id).repository.get()
        ).data

        var selectedGitReference: ScmGitReference? = nil
        var selectedPullRequest: ScmPullRequest? = nil

        switch selectedSourceType {
        case .pullRequest:
            let pullRequests = try await provider.requestAll(
                APIEndpoint.v1.scmRepositories.id(repository.id).pullRequests.get()
            ).flatMap(\.data)

            ActivityIndicator.stop()

            selectedPullRequest = if let pullRequestID {
                pullRequests.first(where: { $0.attributes?.number == pullRequestID })
            } else {
                CommandLine.chooseFromList(pullRequests, prompt: "Select a pull request:")
            }

            if selectedPullRequest == nil, pullRequestID != nil {
                throw Error.couldNotFindPullRequest(availablePullRequests: pullRequests)
            }

        case .reference:
            let gitReferences = try await provider.requestAll(
                APIEndpoint.v1.scmRepositories.id(repository.id).gitReferences.get()
            ).flatMap(\.data)

            ActivityIndicator.stop()

            selectedGitReference = if let reference {
                gitReferences.first(where: { $0.attributes?.name == reference })
            } else {
                CommandLine.chooseFromList(gitReferences, prompt: "Select a reference:")
            }

            guard selectedGitReference != nil else {
                throw Error.couldNotFindReference(availableReferences: gitReferences)
            }
        }
        

        ActivityIndicator.start()
        _ = try await provider.request(APIEndpoint.v1.ciBuildRuns.post(.init(
            data: .init(
                type: .ciBuildRuns,
                relationships: .init(
                    workflow: .init(data: .init(
                        type: .ciWorkflows,
                        id: selectedWorkflow.id
                    )),
                    sourceBranchOrTag: selectedGitReference.map {
                        .init(data: .init(
                            type: .scmGitReferences,
                            id: $0.id
                        ))
                    },
                    pullRequest: selectedPullRequest.map {
                        .init(data: .init(
                            type: .scmPullRequests,
                            id: $0.id
                        ))
                    }
                )
            )
        ))).data
        ActivityIndicator.stop()

        print("✓ ".brightGreen.bold + "Build started")
    }
}

// MARK: xcc.Error

extension xcc {
    enum Error: LocalizedError {
        case couldNotFindProduct(availableProducts: [CiProduct])
        case couldNotFindWorkflow(availableWorkflows: [CiWorkflow])
        case couldNotFindReference(availableReferences: [ScmGitReference])
        case couldNotFindPullRequest(availablePullRequests: [ScmPullRequest])
        case multipleSourceTypes

        // MARK: Internal

        var errorDescription: String? {
            switch self {
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

            case let .couldNotFindPullRequest(pullRequests): """
                Could not find pull request with number. Available references:
                \(pullRequests.compactMap(\.attributes?.number).map { "- \($0)" }.joined(separator: "\n"))
                """

            case .multipleSourceTypes:
                "Please only supply one source argument, either `reference` or `pullRequestID`"
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

// MARK: - ScmPullRequest + CustomStringConvertible

extension ScmPullRequest: CustomStringConvertible {
    public var description: String {
        guard let number = attributes?.number, let title = attributes?.title else {
            return "Unknown"
        }
        
        return "#\(number): \(title)"
    }
}


extension APIProvider {
    func requestAll<T: Decodable>(_ endpoint: Request<T>) async throws -> [T] {
        var results: [T] = []
        for try await pagedResult in paged(endpoint) {
            results.append(pagedResult)
        }
        return results
    }
}

enum SourceType: CustomStringConvertible, CaseIterable {
    case reference
    case pullRequest

    var description: String {
        switch self {
        case .reference:
            "Git Reference (branch/tag)"
        case .pullRequest:
            "Pull Request"
        }
    }
}
