//
//  PhotoCardView.swift
//  Purgatorio
//
//  Vista de referencia que demuestra la integración con PhotoLibraryViewModel.
//  Sirve como contrato de uso para DestructiveSwipeView.
//
//  ⚠️  Este archivo es una vista de INTEGRACIÓN / referencia.
//      La lógica de swipe destructivo se implementará en DestructiveSwipeView.
//

import SwiftUI

/// Vista de referencia: stack de cards con pre-carga de imagen anticipada.
///
/// Demuestra la API de `PhotoLibraryViewModel` y sirve de base para
/// el `DestructiveSwipeView` que aplicará los shaders de Metal.
public struct PhotoCardView: View {

    @StateObject private var viewModel = PhotoLibraryViewModel(queue: PurgatorioQueueManager(container: try! PurgatorioQueueManager.makeContainer(inMemoryOnly: true)))

    // Tamaño del card = pantalla completa (ajustar en DestructiveSwipeView)
    private var cardSize: CGSize { UIScreen.main.bounds.size }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.authState {
            case .notDetermined:
                ProgressView("Solicitando permisos…")
                    .tint(.white)

            case .denied(let reason):
                permissionDeniedView(reason: reason)
            case .restricted:
                permissionDeniedView(reason: "Acceso restringido por políticas del sistema.")

            case .authorized, .limited:
                photoStackView

            }
        }
        .task {
            viewModel.start()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var photoStackView: some View {
        if viewModel.isLoading && viewModel.assets.isEmpty {
            ProgressView("Cargando librería…")
                .tint(.white)
        } else if viewModel.assets.isEmpty {
            Text("No hay fotos disponibles.")
                .foregroundStyle(.secondary)
        } else {
            cardStack
                .overlay(alignment: .bottom) { debugOverlay }
        }
    }

    private var cardStack: some View {
        ZStack {
            // Imagen siguiente (ya pre-cargada, lista para la transición)
            if let next = viewModel.nextImage {
                Image(uiImage: next)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
                    .opacity(0.4)
                    .scaleEffect(0.95)
            }

            // Imagen actual (ya en memoria, cero latencia)
            if let current = viewModel.currentImage {
                Image(uiImage: current)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
                    // HOOK para DestructiveSwipeView:
                    // Aquí se conectará el DragGesture y los shaders de Metal.
                    .onTapGesture {
                        let next = viewModel.currentIndex + 1
                        viewModel.advance(to: next)
                    }
            }
        }
    }

    private var debugOverlay: some View {
        VStack(spacing: 4) {
            Text("Asset \(viewModel.currentIndex + 1) / \(viewModel.assets.count)")
            if case .limited = viewModel.authState {
                Label("Acceso Limitado", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.7))
        .padding(.bottom, 40)
    }

    private func permissionDeniedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.slash.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Sin acceso a la librería")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Abrir Ajustes") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(32)
    }
}
// Build Final v1.0
#Preview {
    PhotoCardView()
}
