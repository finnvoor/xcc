import AppStoreConnect_Swift_SDK
import ArgumentParser
import Foundation
import Noora

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

        var bundleIDs: [BundleID] = []
        var products: [CiProduct] = []
        try await Noora().progressStep(
            message: "Fetching bundle IDs",
            successMessage: "Fetched bundle IDs and products",
            errorMessage: "Failed to fetch bundle IDs and products",
            showSpinner: true
        ) { updateMessage in
            bundleIDs = try await provider.requestAll(
                APIEndpoint.v1.bundleIDs.get(parameters: .init(fieldsBundleIDs: [.identifier], limit: 200))
            ).flatMap(\.data)

            updateMessage("Fetching products")
            products = try await provider.requestAll(
                APIEndpoint.v1.ciProducts.get(parameters: .init(
                    include: [.bundleID]
                ))
            ).flatMap(\.data)
        }

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
            Noora().singleChoicePrompt(
                question: "Select a product",
                options: products,
                filterMode: .enabled
            )
        }
        guard let selectedProduct else {
            throw Error.couldNotFindProduct(availableProducts: products)
        }

        var workflows: [CiWorkflow] = []
        try await Noora().progressStep(
            message: "Fetching workflows",
            successMessage: "Fetched workflows",
            errorMessage: "Failed to fetch workflows",
            showSpinner: true
        ) { _ in
            workflows = try await provider.requestAll(
                APIEndpoint.v1.ciProducts.id(selectedProduct.id).workflows.get()
            ).flatMap(\.data)
        }

        let selectedWorkflow = if let workflow {
            workflows.first(where: { $0.attributes?.name == workflow })
        } else {
            Noora().singleChoicePrompt(
                question: "Select a workflow",
                options: workflows,
                filterMode: .enabled
            )
        }
        guard let selectedWorkflow else {
            throw Error.couldNotFindWorkflow(availableWorkflows: workflows)
        }

        var repository: ScmRepository!
        var pullRequests: [ScmPullRequest] = []
        try await Noora().progressStep(
            message: "Fetching repository",
            successMessage: "Fetched repository and pull requests",
            errorMessage: "Failed to fetch repository and pull requests",
            showSpinner: true
        ) { updateMessage in
            repository = try await provider.request(
                APIEndpoint.v1.ciWorkflows.id(selectedWorkflow.id).repository.get()
            ).data

            updateMessage("Fetching pull requests")

            pullRequests = try await provider.requestAll(
                APIEndpoint.v1.scmRepositories.id(repository.id).pullRequests.get()
            ).flatMap(\.data)
        }

        let selectedSourceType = if reference != nil || pullRequests.isEmpty {
            SourceType.reference
        } else if pullRequestID != nil {
            SourceType.pullRequest
        } else {
            Noora().singleChoicePrompt(question: "Select a source type", options: SourceType.allCases)
        }

        var selectedGitReference: ScmGitReference? = nil
        var selectedPullRequest: ScmPullRequest? = nil

        switch selectedSourceType {
        case .pullRequest:
            selectedPullRequest = if let pullRequestID {
                pullRequests.first(where: { $0.attributes?.number == pullRequestID })
            } else {
                Noora().singleChoicePrompt(
                    question: "Select a pull request",
                    options: pullRequests,
                    filterMode: .enabled
                )
            }

            if selectedPullRequest == nil, pullRequestID != nil {
                throw Error.couldNotFindPullRequest(availablePullRequests: pullRequests)
            }

        case .reference:
            var gitReferences: [ScmGitReference] = []
            try await Noora().progressStep(
                message: "Fetching git references",
                successMessage: "Fetched git references",
                errorMessage: "Failed to fetch git references",
                showSpinner: true
            ) { _ in
                gitReferences = try await provider.requestAll(
                    APIEndpoint.v1.scmRepositories.id(repository.id).gitReferences.get()
                ).flatMap(\.data)
            }

            selectedGitReference = if let reference {
                gitReferences.first(where: { $0.attributes?.name == reference })
            } else {
                Noora().singleChoicePrompt(
                    question: "Select a reference",
                    options: gitReferences,
                    filterMode: .enabled
                )
            }

            guard selectedGitReference != nil else {
                throw Error.couldNotFindReference(availableReferences: gitReferences)
            }
        }

        try await Noora().progressStep(
            message: "Starting CI build run",
            successMessage: "CI build run started",
            errorMessage: "Failed to start CI build run",
            showSpinner: true
        ) { _ in
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
        }

        Noora().success(.alert("Build started"))
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

extension CiProduct: @retroactive CustomStringConvertible, @retroactive Equatable {
    public static func == (lhs: AppStoreConnect_Swift_SDK.CiProduct, rhs: AppStoreConnect_Swift_SDK.CiProduct) -> Bool {
        lhs.id == rhs.id
    }

    public var description: String {
        let name = attributes?.name ?? "Unknown"
        let bundleID = relationships?.bundleID?.data
        return bundleID.map { Noora().format("\(name) \(.muted("(\($0.id))"))") } ?? name
    }
}

// MARK: - CiWorkflow + CustomStringConvertible

extension CiWorkflow: @retroactive CustomStringConvertible, @retroactive Equatable {
    public static func == (lhs: AppStoreConnect_Swift_SDK.CiWorkflow, rhs: AppStoreConnect_Swift_SDK.CiWorkflow) -> Bool {
        lhs.id == rhs.id
    }

    public var description: String {
        attributes?.name ?? "Unknown"
    }
}

// MARK: - ScmGitReference + CustomStringConvertible

extension ScmGitReference: @retroactive CustomStringConvertible, @retroactive Equatable {
    public static func == (
        lhs: AppStoreConnect_Swift_SDK.ScmGitReference,
        rhs: AppStoreConnect_Swift_SDK.ScmGitReference
    ) -> Bool {
        lhs.id == rhs.id
    }

    public var description: String {
        switch attributes?.kind {
        case .branch:
            Noora().format("\(.muted("(branch)")) \(attributes?.name ?? "")")
        case .tag:
            Noora().format("\(.muted("   (tag)")) \(attributes?.name ?? "")")
        case nil:
            attributes?.name ?? ""
        }
    }
}

// MARK: - ScmPullRequest + CustomStringConvertible

extension ScmPullRequest: @retroactive CustomStringConvertible, @retroactive Equatable {
    public static func == (
        lhs: AppStoreConnect_Swift_SDK.ScmPullRequest,
        rhs: AppStoreConnect_Swift_SDK.ScmPullRequest
    ) -> Bool {
        lhs.id == rhs.id
    }

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

// MARK: - SourceType

enum SourceType: CustomStringConvertible, CaseIterable {
    case reference
    case pullRequest

    // MARK: Internal

    var description: String {
        switch self {
        case .reference:
            "Git Reference (branch/tag)"
        case .pullRequest:
            "Pull Request"
        }
    }
}
