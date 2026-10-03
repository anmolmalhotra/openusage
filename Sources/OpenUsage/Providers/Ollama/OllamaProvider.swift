import Foundation

@MainActor
final class OllamaProvider: ProviderRuntime {
    let provider = Provider(
        id: "ollama",
        displayName: "Ollama",
        icon: .providerMark("ollama"),
        links: [
            ProviderLink(label: "Usage", url: "https://ollama.com/settings"),
            ProviderLink(label: "API Keys", url: "https://ollama.com/settings/keys")
        ]
    )
    
    /// One notice for every way the plan can go missing, so a failed request and an unreadable response
    /// read the same to the user — the badge is gone for a reason, and the meters are still current.
    private static let planWarning = "Couldn't read your Ollama plan. Usage below is still up to date."
    
    let authStore: OllamaAuthStore
    let usageClient: OllamaUsageClient
    let piUsageScanner: PiUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date
    
    init(
        authStore: OllamaAuthStore = OllamaAuthStore(),
        usageClient: OllamaUsageClient = OllamaUsageClient(),
        piUsageScanner: PiUsageScanner = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.piUsageScanner = piUsageScanner
        self.pricing = pricing
        self.now = now
    }
    
    var widgetDescriptors: [WidgetDescriptor] {
        [
            // Not `isSessionWindow`: that treatment ("Not started" on a fresh pool) needs a reset date,
            // and Ollama publishes none — see `OllamaUsageMapper`.
            .percent(id: "ollama.session", provider: provider, title: "Session",
                     metricLabel: "Session")
                .exportingLimit("session", unit: "percent"),
            .percent(id: "ollama.weekly", provider: provider, title: "Weekly",
                     metricLabel: "Weekly")
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "ollama.monthly", provider: provider, title: "Monthly",
                     metricLabel: "Monthly")
                .exportingLimit("monthly", unit: "percent"),
            // Ollama reports recent spend as a single rolling four-week total, not a daily history, so
            // this is one unbounded dollar row rather than the Today/Yesterday/Last 30 Days tiles the
            // local-scanner providers ship.
            //
            // Deliberately not `isUsagePeriod`: that marks a row where $0.00 means nothing was used, and
            // this row counts charges *beyond* the plan. A subscriber can run Ollama hard all month and
            // still sit at $0.00, so the "No usage in this period" hover would be plainly wrong.
            .values(id: "ollama.last4Weeks", provider: provider, title: "Last 4 Weeks",
                    metricLabel: "Last 4 Weeks", selection: .kind(.dollars),
                    valueWord: "spent"),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: "From your pi sessions (estimated)"
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }
    
    /// The signing key alone does not prove an Ollama Cloud account is linked. Keep Cloud opt-in,
    /// but detect actual pi sessions because those can populate local history without Cloud access.
    func hasLocalCredentials() async -> Bool {
        await piUsageScanner.hasUsage(cardID: provider.id)
    }
    
    func refresh() async -> ProviderSnapshot {
        let snapshot = await refreshNative()
        let refreshedAt = now()
        let scan = await piUsageScanner.scan(cardID: provider.id, now: refreshedAt, pricing: await pricing())
        return PiUsageHistory.appending(
            scan, to: snapshot, sourceNote: "From your pi sessions (estimated)", now: refreshedAt
        )
    }
    
    private func refreshNative() async -> ProviderSnapshot {
        let key: OllamaSigningKey?
        do {
            key = try await loadOffMainActor { [authStore] in try authStore.loadSigningKey() }
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        guard let key else {
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.missingKey)
        }
        
        // The usage endpoint is required; the account endpoint is best-effort (plan name only), so a
        // failure there must not blank out the meters.
        let usage = await load { try await usageClient.fetchUsage(key: key) }
        let account = await loadAccount { try await usageClient.fetchAccount(key: key) }
        
        var accountBody: Data?
        var warning: String?
        switch account {
        case .success(let body):
            accountBody = body
        case .failure(let error):
            // Best-effort does not mean invisible: without this, a persistently failing plan lookup just
            // looks like an account that has no plan. Log it and carry an amber notice so the missing
            // badge is explained, while the meters below still refresh normally.
            AppLog.warn(.refresh, "ollama plan lookup failed (\(error.errorCategory.rawValue)); meters unaffected")
            warning = Self.planWarning
        }
        
        switch usage {
        case .success(let body):
            do {
                let mapped = try OllamaUsageMapper.map(usageBody: body, accountBody: accountBody)
                // A 200 carrying a body OpenUsage can't read drops the badge exactly as silently as a
                // failed request did, so it earns the same notice. An account that simply has no plan
                // (`.absent`) stays quiet — that is ordinary, not a fault.
                if warning == nil, mapped.plan == .unreadable {
                    AppLog.warn(.refresh, "ollama plan response unreadable; meters unaffected")
                    warning = Self.planWarning
                }
                return ProviderSnapshot.make(provider: provider, plan: mapped.plan.name, lines: mapped.lines,
                                             refreshedAt: now(), warning: warning)
            } catch {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
        case .authFailure:
            // The key parsed and signed fine, so a 401/403 means ollama.com doesn't know it: the user has
            // Ollama installed but has never run `ollama signin` (or has signed out since).
            return ProviderSnapshot.error(provider: provider, error: OllamaAuthError.notSignedIn)
        case .failed(let error):
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }
    
    /// Run the required usage call and classify the outcome: the body on 2xx, an auth failure on
    /// 401/403, or a typed failure for any other non-2xx or transport error.
    private func load(_ call: () async throws -> HTTPResponse) async -> UsageResult {
        do {
            let response = try await call()
            if response.statusCode == 401 || response.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failed(.connectionFailed)
        }
    }
    
    /// Run the best-effort account call. It never throws into the snapshot — a transport error or a
    /// non-2xx just means "no plan name this refresh" — but it returns *why* so the caller can log the
    /// failure and warn, rather than letting it disappear.
    private func loadAccount(_ call: () async throws -> HTTPResponse) async -> Result<Data, OllamaUsageError> {
        do {
            let response = try await call()
            guard (200..<300).contains(response.statusCode) else {
                return .failure(.requestFailed(response.statusCode))
            }
            return .success(response.body)
        } catch {
            return .failure(.connectionFailed)
        }
    }
}

private enum UsageResult {
    case success(Data)
    case authFailure
    case failed(OllamaUsageError)
}
