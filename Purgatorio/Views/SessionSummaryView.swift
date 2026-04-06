//
//  SessionSummaryView.swift
//  Purgatorio
//
//  Pantalla de resumen de sesión + Toast de milestone.
//
//  Se presenta como sheet al terminar la sesión (showSessionSummary == true).
//  Muestra estadísticas: fotos destruidas, salvadas, bytes de basura detectada.
//  En rama Google: botón prominente "Vaciar Purgatorio en Google Photos".
//

import SwiftUI

// MARK: - SessionSummaryView

public struct SessionSummaryView: View {

    @EnvironmentObject private var vm: PhotoLibraryViewModel
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 32) {

                // Header icon
                ZStack {
                    Circle()
                        .fill(.red.gradient.opacity(0.15))
                        .frame(width: 100, height: 100)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red.gradient)
                }
                .padding(.top, 24)

                // Title
                Text("Sesión completada")
                    .font(.title.bold())

                // Stats grid
                VStack(spacing: 16) {
                    statsRow(
                        icon: "flame.fill",
                        color: .red,
                        label: "Destruidas",
                        value: "\(vm.sessionStats.destroyed)"
                    )
                    statsRow(
                        icon: "heart.fill",
                        color: .green,
                        label: "Salvadas",
                        value: "\(vm.sessionStats.rescued)"
                    )

                    Divider()
                        .padding(.horizontal)

                    statsRow(
                        icon: "externaldrive.fill",
                        color: .orange,
                        label: "Total de basura detectada",
                        value: vm.sessionStats.formattedBytes
                    )
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal)

                Spacer()

                // Botones de acción
                VStack(spacing: 12) {
                    if vm.activeSource == .google && vm.sessionStats.destroyed > 0 {
                        Button {
                            vm.openGooglePurgatory()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.right.square.fill")
                                Text("Vaciar Purgatorio en Google Photos")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.red.gradient, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .shadow(color: .red.opacity(0.3), radius: 12, x: 0, y: 6)
                    }

                    Button {
                        vm.resetSession()
                        dismiss()
                    } label: {
                        Text("Cerrar")
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Listo") {
                        vm.resetSession()
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func statsRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 32)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .contentTransition(.numericText())
        }
        .padding(.horizontal)
    }
}

// MARK: - MilestoneToast

/// Toast animado para hitos de 25 fotos.
///
/// Integración en la vista raíz:
/// ```swift
/// .overlay(alignment: .top) {
///     if let milestone = vm.activeMilestone {
///         MilestoneToast(event: milestone)
///     }
/// }
/// ```
public struct MilestoneToast: View {

    let event: MilestoneEvent

    @State private var appeared = false

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.title2)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("¡Hito: \(event.count) fotos!")
                    .font(.subheadline.bold())
                Text(event.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 24)
        .padding(.top, 60)
        .offset(y: appeared ? 0 : -120)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                appeared = true
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Preview

#Preview("Summary") {
    SessionSummaryView()
}

#Preview("Milestone Toast") {
    MilestoneToast(event: MilestoneEvent(
        count: 50,
        message: "¡Hito alcanzado! 25 fotos más listas para el Purgatorio. Sigue triturando."
    ))
}
