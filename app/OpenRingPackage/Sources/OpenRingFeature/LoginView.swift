import SwiftUI
import RingClient

// MARK: - Sign in (Doorstep design: frosted backdrop, type-led, one primary action)

public struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showTwoFactor = false
    @State private var twoFactorPrompt = ""
    @FocusState private var focus: Field?

    private enum Field { case email, password, code }

    let onLoginSuccess: () -> Void

    public init(onLoginSuccess: @escaping () -> Void) {
        self.onLoginSuccess = onLoginSuccess
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DoorstepWordmark(size: 20)
                .padding(.bottom, 26)

            if showTwoFactor {
                twoFactorForm
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            } else {
                signInForm
                    .transition(.opacity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(DS.meta)
                    .foregroundStyle(DS.ember)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .padding(32)
        .frame(width: DS.wallWidth, alignment: .leading)
        .background(Backdrop())
        .animation(DS.settle, value: showTwoFactor)
        .animation(DS.settle, value: errorMessage)
        .onAppear { focus = .email }
    }

    // MARK: Sign in

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sign in to Ring")
                .font(DS.display)
                .foregroundStyle(DS.paper)
            Text("Doorstep connects straight to your Ring account.\nYour sign-in stays in this Mac's Keychain.")
                .font(DS.body)
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 24)

            VStack(spacing: 10) {
                GlassField(placeholder: "Email", text: $email)
                    .focused($focus, equals: .email)
                    .textContentType(.username)
                    .onSubmit { focus = .password }
                GlassField(placeholder: "Password", text: $password, secure: true)
                    .focused($focus, equals: .password)
                    .textContentType(.password)
                    .onSubmit { if canLogin { Task { await performLogin() } } }
            }
            .frame(maxWidth: 360)

            HStack(spacing: 12) {
                PrimaryButton(title: "Continue", isLoading: isLoading, enabled: canLogin) {
                    Task { await performLogin() }
                }
                Text("Ring will text you a code next.")
                    .font(DS.meta)
                    .foregroundStyle(DS.ash)
            }
            .padding(.top, 20)
        }
    }

    // MARK: Two-factor

    private var twoFactorForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Enter your code")
                .font(DS.display)
                .foregroundStyle(DS.paper)
            Text(twoFactorPrompt.isEmpty ? "Ring sent a code to your phone." : twoFactorPrompt)
                .font(DS.body)
                .foregroundStyle(DS.ash)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 24)

            GlassField(placeholder: "123456", text: $twoFactorCode, monospaced: true)
                .focused($focus, equals: .code)
                .textContentType(.oneTimeCode)
                .frame(maxWidth: 200)
                .onSubmit { if twoFactorCode.count >= 6 { Task { await submitTwoFactor() } } }
                .onAppear { focus = .code }

            HStack(spacing: 16) {
                PrimaryButton(title: "Verify", isLoading: isLoading, enabled: twoFactorCode.count >= 6) {
                    Task { await submitTwoFactor() }
                }
                Button("Use a different account") {
                    showTwoFactor = false
                    twoFactorCode = ""
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .font(DS.body)
                .foregroundStyle(DS.ash)
            }
            .padding(.top, 20)
        }
    }

    // MARK: Logic (unchanged from open-ring)

    private var canLogin: Bool {
        !email.isEmpty && !password.isEmpty
    }

    private func performLogin() async {
        isLoading = true
        errorMessage = nil
        do {
            try await RingClient.shared.login(email: email, password: password)
            await MainActor.run { onLoginSuccess() }
        } catch let error as RingAuthError {
            await MainActor.run {
                switch error {
                case .requiresTwoFactor(let prompt):
                    twoFactorPrompt = prompt
                    showTwoFactor = true
                default:
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func submitTwoFactor() async {
        isLoading = true
        errorMessage = nil
        do {
            try await RingClient.shared.submitTwoFactorCode(twoFactorCode)
            await MainActor.run { onLoginSuccess() }
        } catch let error as RingAuthError {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        } catch {
            await MainActor.run {
                // Say what actually failed (e.g. saving to the Keychain), not a shrug.
                errorMessage = "Couldn't finish signing in: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}

// MARK: - Pieces

/// A text field sitting on glass: translucent well, no border, focus ring from the system.
private struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var monospaced = false
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if secure && !reveal {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? Font.system(size: 20, weight: .medium, design: .monospaced) : DS.body)
            .foregroundStyle(DS.paper)

            if secure {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ash)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reveal ? "Hide password" : "Show password")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: monospaced ? 44 : 36)
        .background(DS.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PrimaryButton: View {
    let title: String
    let isLoading: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView().controlSize(.small).tint(DS.night) }
                Text(title).font(DS.bodyStrong)
            }
            .foregroundStyle(enabled ? DS.night : DS.ash)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(enabled ? DS.paper : DS.well, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || isLoading)
        .keyboardShortcut(.defaultAction)
    }
}
