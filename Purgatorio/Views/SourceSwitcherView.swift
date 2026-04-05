//
//  SourceSwitcherView.swift
//  Purgatorio
//
//  Toggle de selección de fuente de datos: Apple Photos o Google Photos.
//
//  Diseño:
//    Segmented control glassmorphic flotante en la parte superior de la pantalla.
//    Cada segmento muestra icono + label. Cambiar de fuente resetea la sesión.
//
//  Integración:
//    Bind directo a PhotoLibraryViewModel.activeSource.
//    El ViewModel se encarga de resetear assets, imágenes y estadísticas.
//

import SwiftUI

// MARK: - SourceSwitcherView

public struct SourceSwitcherView: View {

    @EnvironmentObject private var vm: PhotoLibraryViewModel

    @Namespace private var animation

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(PhotoSourceType.allCases) { source in
                sourceButton(source)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }

    // MARK: - Private

    private func sourceButton(_ source: PhotoSourceType) -> some View {
        let isActive = vm.activeSource == source

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                vm.switchSource(to: source)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: source.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(source == .apple ? "iPhone" : "Google")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? .white : .secondary)
            .background {
                if isActive {
                    Capsule()
                        .fill(source == .apple
                              ? Color.blue.gradient
                              : Color.red.gradient)
                        .matchedGeometryEffect(id: "activeSource", in: animation)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.rawValue)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - SessionStatsBar

/// Barra inferior que muestra las estadísticas de la sesión actual.
public struct SessionStatsBar: View {

    @EnvironmentObject private var vm: PhotoLibraryViewModel

    public init() {}

    public var body: some View {
        HStack(spacing: 20) {
            statItem(
                icon: "flame.fill",
                count: vm.sessionStats.destroyed,
                label: "Destruidas",
                color: .red
            )
            statItem(
                icon: "heart.fill",
                count: vm.sessionStats.rescued,
                label: "Salvadas",
                color: .green
            )

            Spacer()

            // Botón Google Photos (solo visible en rama Google cuando hay pendientes)
            if vm.showGooglePurgeButton {
                Button {
                    vm.openGooglePurgatory()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text("Vaciar Purgatorio")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.gradient, in: Capsule())
                    .foregroundStyle(.white)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.spring(response: 0.4), value: vm.showGooglePurgeButton)
    }

    private func statItem(icon: String, count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14))
            Text("\(count)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - RescueButton

/// Botón de salvación para la foto actual.
/// Se integra debajo o al lado de la carta en la DestructiveSwipeView.
public struct RescueButton: View {

    @EnvironmentObject private var vm: PhotoLibraryViewModel

    public init() {}

    public var body: some View {
        Button {
            Task { await vm.rescueCurrent() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "heart.circle.fill")
                    .font(.title3)
                Text("Salvar")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.green.gradient, in: Capsule())
            .foregroundStyle(.white)
            .shadow(color: .green.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Salvar esta foto")
    }
}

// MARK: - Preview

#Preview {
    let container = try! PurgatorioQueueManager.makeContainer(inMemoryOnly: true)
    let queue = PurgatorioQueueManager(container: container)
    let vm = PhotoLibraryViewModel(queue: queue)

    return VStack(spacing: 20) {
        SourceSwitcherView()
        Spacer()
        RescueButton()
        SessionStatsBar()
    }
    .padding()
    .background(Color(.systemBackground))
    .environmentObject(vm)
}

