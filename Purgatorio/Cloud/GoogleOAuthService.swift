//
//  GoogleOAuthService.swift
//  Purgatorio
//
//  Servicio de autenticación OAuth 2.0 con Google Photos API.
//
//  Flujo:
//    1. ASWebAuthenticationSession abre el consent screen de Google.
//    2. El redirect URI (custom URL scheme) retorna el authorization code.
//    3. Se intercambia por access_token + refresh_token vía POST a /token.
//    4. Ambos tokens se almacenan en el Keychain (kSecClassGenericPassword).
//    5. El access_token se renueva automáticamente antes de expirar.
//
//  Seguridad:
//    - Tokens NUNCA se guardan en UserDefaults ni en disco plano.
//    - Se usa kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly para
//      que los tokens estén disponibles en background upload pero no
//      sean extraíbles de un backup de iTunes.
//

import AuthenticationServices
import Foundation
import Security
import os.log

// MARK: - Configuration

public enum GoogleOAuthConfig {
    /// Client ID de la Google Cloud Console (tipo iOS).
    /// REEMPLAZAR con tu valor real antes de compilar.
    static let clientID     = "YOUR_CLIENT_ID.apps.googleusercontent.com"
    /// Redirect URI registrado en la consola. Debe coincidir con el URL scheme del Info.plist.
    static let redirectURI  = "com.purgatorio.app:/oauth2callback"
    /// Scopes mínimos: lectura/escritura de la biblioteca y gestión de álbumes compartidos.
    static let scopes       = "https://www.googleapis.com/auth/photoslibrary https://www.googleapis.com/auth/photoslibrary.sharing"

    static let authEndpoint  = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
}

// MARK: - Token Model

public struct OAuthTokens: Codable, Sendable {
    public let accessToken:  String
    public let refreshToken: String?
    public let expiresIn:    Int          // Segundos desde la emisión
    public let tokenType:    String       // "Bearer"
    public let obtainedAt:   Date         // Timestamp local de obtención

    /// `true` si el token expira en menos de 60 segundos.
    public var isExpired: Bool {
        Date().timeIntervalSince(obtainedAt) >= Double(expiresIn - 60)
    }

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
        case obtainedAt
    }
}

// MARK: - Errors

public enum GoogleOAuthError: Error, LocalizedError {
    case authSessionFailed(Error?)
    case noAuthorizationCode
    case tokenExchangeFailed(statusCode: Int, body: String)
    case refreshFailed(statusCode: Int, body: String)
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed
    case notAuthenticated
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .authSessionFailed(let e):
            return "Autenticación cancelada o fallida: \(e?.localizedDescription ?? "unknown")"
        case .noAuthorizationCode:
            return "No se recibió authorization code en el callback."
        case .tokenExchangeFailed(let code, let body):
            return "Token exchange falló (HTTP \(code)): \(body)"
        case .refreshFailed(let code, let body):
            return "Token refresh falló (HTTP \(code)): \(body)"
        case .keychainWriteFailed(let status):
            return "Keychain write falló: \(status)"
        case .keychainReadFailed:
            return "No se encontraron tokens en el Keychain."
        case .notAuthenticated:
            return "No hay sesión activa. Llama a authenticate() primero."
        case .invalidResponse:
            return "Respuesta inválida del servidor de OAuth."
        }
    }
}

// MARK: - GoogleOAuthService

/// Servicio de autenticación OAuth 2.0 para Google Photos.
///
/// Thread-safe: todas las operaciones de token pasan por el actor.
/// Los tokens se persisten en el Keychain inmediatamente tras la obtención.
///
/// ```swift
/// let oauth = GoogleOAuthService()
/// try await oauth.authenticate(presenting: windowScene)
/// let token = try await oauth.validAccessToken()
/// // → "ya29.a0AfH6SM..."
/// ```
public actor GoogleOAuthService {

    // MARK: - Keychain Keys
    private let keychainService   = "com.purgatorio.oauth"
    private let keychainAccount   = "google_tokens"

    // MARK: - State
    private var cachedTokens: OAuthTokens?

    private let logger = Logger(subsystem: "com.purgatorio.app", category: "GoogleOAuth")

    // MARK: - Init

    public init() {
        // Intentar restaurar tokens del Keychain al iniciar
        cachedTokens = loadTokensFromKeychain()
        if cachedTokens != nil {
            logger.info("Tokens restaurados del Keychain.")
        }
    }

    // MARK: - Public API

    /// `true` si hay tokens válidos (o renovables) disponibles.
    public var isAuthenticated: Bool { cachedTokens != nil }

    /// Inicia el flujo de autenticación OAuth completo.
    ///
    /// Abre un `ASWebAuthenticationSession` con el consent screen de Google.
    /// Al completar, intercambia el auth code por tokens y los guarda en Keychain.
    ///
    /// - Parameter anchor: `ASPresentationAnchor` (típicamente la `UIWindow` de la escena).
    @MainActor
    public func authenticate(anchor: ASPresentationAnchor) async throws {
        let code = try await performAuthSession(anchor: anchor)
        let tokens = try await exchangeCodeForTokens(code)
        await storeTokens(tokens)
    }

    /// Retorna un access token válido, renovándolo si es necesario.
    ///
    /// - Throws: `GoogleOAuthError.notAuthenticated` si no hay sesión.
    public func validAccessToken() async throws -> String {
        guard var tokens = cachedTokens else {
            throw GoogleOAuthError.notAuthenticated
        }

        if tokens.isExpired {
            logger.info("Access token expirado — refrescando…")
            tokens = try await refreshAccessToken(tokens)
            storeTokensSync(tokens)
        }

        return tokens.accessToken
    }

    /// Cierra la sesión: borra tokens de memoria y Keychain.
    public func signOut() {
        cachedTokens = nil
        deleteTokensFromKeychain()
        logger.info("Sesión cerrada. Tokens eliminados.")
    }

    // MARK: - Private: ASWebAuthenticationSession

    @MainActor
    private func performAuthSession(anchor: ASPresentationAnchor) async throws -> String {
        var components = URLComponents(string: GoogleOAuthConfig.authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id",     value: GoogleOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri",  value: GoogleOAuthConfig.redirectURI),
            URLQueryItem(name: "response_type",  value: "code"),
            URLQueryItem(name: "scope",          value: GoogleOAuthConfig.scopes),
            URLQueryItem(name: "access_type",    value: "offline"),     // Para refresh_token
            URLQueryItem(name: "prompt",         value: "consent"),     // Forzar consent para refresh
        ]

        let authURL = components.url!
        let scheme  = URL(string: GoogleOAuthConfig.redirectURI)!.scheme

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: GoogleOAuthError.authSessionFailed(error))
                    return
                }
                guard let callbackURL,
                      let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code  = comps.queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: GoogleOAuthError.noAuthorizationCode)
                    return
                }
                continuation.resume(returning: code)
            }

            // Crear un provider en el closure scope
            let provider = SessionPresentationProvider(anchor: anchor)
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    // MARK: - Private: Token Exchange

    private func exchangeCodeForTokens(_ code: String) async throws -> OAuthTokens {
        var request = URLRequest(url: URL(string: GoogleOAuthConfig.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code":          code,
            "client_id":     GoogleOAuthConfig.clientID,
            "redirect_uri":  GoogleOAuthConfig.redirectURI,
            "grant_type":    "authorization_code",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
         .joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthError.invalidResponse
        }

        guard http.statusCode == 200 else {
            throw GoogleOAuthError.tokenExchangeFailed(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        var tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        // Inyectar timestamp de obtención (el servidor no lo envía)
        tokens = OAuthTokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresIn: tokens.expiresIn,
            tokenType: tokens.tokenType,
            obtainedAt: Date()
        )

        logger.info("Token exchange exitoso. expires_in=\(tokens.expiresIn)s")
        return tokens
    }

    // MARK: - Private: Token Refresh

    private func refreshAccessToken(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw GoogleOAuthError.notAuthenticated
        }

        var request = URLRequest(url: URL(string: GoogleOAuthConfig.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id":     GoogleOAuthConfig.clientID,
            "refresh_token": refreshToken,
            "grant_type":    "refresh_token",
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleOAuthError.invalidResponse
        }

        guard http.statusCode == 200 else {
            // Si el refresh falla con 400/401, el refresh token fue revocado
            if http.statusCode == 400 || http.statusCode == 401 {
                signOut()
            }
            throw GoogleOAuthError.refreshFailed(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let refreshed = try JSONDecoder().decode(OAuthTokens.self, from: data)
        // El refresh response NO incluye refresh_token: conservar el original.
        let merged = OAuthTokens(
            accessToken:  refreshed.accessToken,
            refreshToken: refreshToken,           // Conservar el original
            expiresIn:    refreshed.expiresIn,
            tokenType:    refreshed.tokenType,
            obtainedAt:   Date()
        )

        logger.info("Token refreshed. Nuevo expires_in=\(merged.expiresIn)s")
        return merged
    }

    // MARK: - Private: Token Storage (sync, en el executor del actor)

    private func storeTokens(_ tokens: OAuthTokens) {
        storeTokensSync(tokens)
    }

    private func storeTokensSync(_ tokens: OAuthTokens) {
        cachedTokens = tokens
        saveTokensToKeychain(tokens)
    }

    // MARK: - Private: Keychain

    private func saveTokensToKeychain(_ tokens: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }

        // Borrar entrada previa (upsert)
        let deleteQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String:         kSecClassGenericPassword,
            kSecAttrService as String:   keychainService,
            kSecAttrAccount as String:   keychainAccount,
            kSecValueData as String:     data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain write falló: \(status)")
        }
    }

    private func loadTokensFromKeychain() -> OAuthTokens? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    private func deleteTokensFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - ASWebAuthenticationSession Presentation Provider

private final class SessionPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}
