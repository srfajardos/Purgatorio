//
//  ExecutionRouter.swift
//  Purgatorio
//
//  Deep Link router: dirige al usuario al álbum "Purgatorio" de Google Photos.
//
//  Estrategia:
//    1. Intenta abrir la app nativa de Google Photos vía URL scheme:
//       googlephotos://album/{album_id}
//    2. Si la app no está instalada (canOpenURL retorna false), redirige
//       a la versión web: https://photos.google.com/album/{album_id}
//    3. Si no hay album_id disponible, abre la biblioteca general.
//
//  Requisito Info.plist:
//    LSApplicationQueriesSchemes debe incluir "googlephotos" para que
//    canOpenURL() funcione en iOS 9+.
//

import UIKit
import os.log

// MARK: - ExecutionRouter

@MainActor
public enum ExecutionRouter {

    // MARK: - URL Schemes

    /// URL scheme de la app nativa de Google Photos.
    private static let nativeScheme = "googlephotos"

    /// Base URL de Google Photos web.
    private static let webBaseURL   = "https://photos.google.com"

    private static let logger = Logger(subsystem: "com.purgatorio.app", category: "ExecutionRouter")

    // MARK: - Public API

    /// Genera la URL apropiada para abrir el álbum "Purgatorio".
    ///
    /// - Parameter albumID: ID del álbum de Google Photos. `nil` si no se ha creado aún.
    /// - Returns: Tupla con la URL y un booleano indicando si es la app nativa.
    public static func makeAlbumURL(albumID: String?) -> (url: URL, isNativeApp: Bool) {
        if let albumID, isGooglePhotosInstalled() {
            // App nativa disponible
            let url = URL(string: "\(nativeScheme)://album/\(albumID)")!
            return (url, true)
        } else if let albumID {
            // App no instalada → web
            let url = URL(string: "\(webBaseURL)/album/\(albumID)")!
            return (url, false)
        } else {
            // Sin álbum → abrir biblioteca general
            let url = isGooglePhotosInstalled()
                ? URL(string: "\(nativeScheme)://")!
                : URL(string: webBaseURL)!
            return (url, isGooglePhotosInstalled())
        }
    }

    /// Abre el álbum "Purgatorio" en Google Photos.
    ///
    /// Si la app nativa está instalada, la abre directamente.
    /// Si no, abre Safari con la versión web.
    ///
    /// - Parameters:
    ///   - albumID: ID del álbum de Google Photos.
    ///   - completion: Callback con el resultado de la apertura.
    @MainActor
    public static func openPurgatoryAlbum(
        albumID: String?,
        completion: ((Bool) -> Void)? = nil
    ) {
        let (url, isNative) = makeAlbumURL(albumID: albumID)

        logger.info("Abriendo Google Photos: \(url.absoluteString) (nativa=\(isNative))")

        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                logger.info("Google Photos abierto exitosamente.")
            } else {
                logger.warning("No se pudo abrir Google Photos. Intentando URL web fallback…")
                // Fallback: si la apertura nativa falló, intentar web
                if isNative, let albumID {
                    let webURL = URL(string: "\(webBaseURL)/album/\(albumID)")!
                    UIApplication.shared.open(webURL, options: [:]) { webSuccess in
                        completion?(webSuccess)
                    }
                    return
                }
            }
            completion?(success)
        }
    }

    /// Genera un deep link compartible como texto.
    ///
    /// Útil para enviar el link del álbum por AirDrop, Messages, etc.
    ///
    /// - Parameter albumID: ID del álbum de Google Photos.
    /// - Returns: URL string web (siempre funciona en cualquier dispositivo).
    public static func makeShareableLink(albumID: String) -> String {
        "\(webBaseURL)/album/\(albumID)"
    }

    // MARK: - App Detection

    /// Verifica si Google Photos está instalado en el dispositivo.
    ///
    /// Requiere `LSApplicationQueriesSchemes: ["googlephotos"]` en Info.plist.
    /// Sin esta entrada, iOS silenciosamente retorna `false` por sandbox.
    public static func isGooglePhotosInstalled() -> Bool {
        guard let url = URL(string: "\(nativeScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    // MARK: - Info.plist Requirement

    /// Helper para verificar que Info.plist tiene la configuración necesaria.
    ///
    /// Llamar en DEBUG builds durante app init para detectar configuraciones faltantes.
    public static func validateInfoPlistConfiguration() {
        #if DEBUG
        let schemes = Bundle.main.object(forInfoDictionaryKey: "LSApplicationQueriesSchemes") as? [String] ?? []
        if !schemes.contains("googlephotos") {
            logger.critical(
                "⚠️ Info.plist falta: LSApplicationQueriesSchemes no incluye 'googlephotos'. " +
                "canOpenURL() siempre retornará false."
            )
        }

        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let registeredSchemes = urlTypes.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
        if !registeredSchemes.contains(where: { $0.starts(with: "com.purgatorio") }) {
            logger.critical(
                "⚠️ Info.plist falta: CFBundleURLTypes no incluye el scheme de redirect OAuth. " +
                "El callback de ASWebAuthenticationSession fallará."
            )
        }
        #endif
    }
}
