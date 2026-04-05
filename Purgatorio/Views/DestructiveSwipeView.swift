//
//  DestructiveSwipeView.swift
//  Purgatorio
//
//  v3.0 — Dos Silos Independientes
//
//  La vista de destrucción es AGNÓSTICA de la fuente de datos.
//  La UX visceral (Metal, Haptics, Audio) es idéntica para Apple y Google.
//
//  Flujo:
//    1. IntentPredictor → pre-calienta VRAM + haptics
//    2. DragGesture.onChanged → rugosidad háptica continua
//    3. DragGesture.onEnded (velocity > 1500 pts/s)
//       → Metal shredder + Haptic + Audio (UX idéntica)
//       → vm.processDecision(.destroy)  ← el VM decide Apple delete vs Google enqueue
//    4. Swipe lento / tap corazón
//       → vm.processDecision(.rescue)   ← ignora, avanza
//

import SwiftUI
import UIKit

// MARK: - DestructiveSwipeView

public struct DestructiveSwipeView: View {

    // MARK: - Dependencies
    let provider:  PhotoProviderActor
    let predictor: IntentPredictor

    @EnvironmentObject private var vm: PhotoLibraryViewModel
    @ObservedObject    private var thermal = ThermalGovernor.shared

    // MARK: - Gesture State
    @State private var dragOffset:     CGSize  = .zero
    @State private var dragRotation:   Angle   = .zero
    @State private var isDragging:     Bool    = false
    @State private var rugosityStarted: Bool   = false

    // MARK: - Card Visibility
    @State private var cardVisible:    Bool    = true
    @State private var cardOpacity:    Double  = 1

    // MARK: - Quality Profile (computed once per loaded texture)
    @State private var qualityProfile: PhotoQualityProfile?

    // MARK: - Global Frame
    @State private var cardGlobalFrame: CGRect = .zero

    // MARK: - Critical Thermal Fallback
    @State private var criticalScale:   CGFloat = 1
    @State private var criticalOpacity: Double  = 1

    // MARK: - Constants
    private let velocityThreshold: CGFloat = 1500
    private let rotationFactor:    CGFloat = 0.05

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                if cardVisible {
                    cardView
                        .scaleEffect(criticalScale)
                        .opacity(cardOpacity * criticalOpacity)
                        .offset(dragOffset)
                        .rotationEffect(dragRotation)
                        .background(
                            GeometryReader { cardGeo in
                                Color.clear.onAppear {
                                    cardGlobalFrame = cardGeo.frame(in: .global)
                                }.onChange(of: dragOffset) { _, _ in
                                    cardGlobalFrame = cardGeo.frame(in: .global)
                                }
                            }
                        )
                        .gesture(swipeGesture(in: geometry))
                }

                // Rescue button — visible solo durante el arrastre lento
                VStack {
                    Spacer()
                    RescueButton()
                        .opacity(isDragging ? 0.3 : 1)
                        .padding(.bottom, 24)
                }
            }
        }
        .onAppear { setupIntentPredictor() }
        .onDisappear { Task { await predictor.stopMonitoring() } }
        .task { await computeQualityProfile() }
    }

    // MARK: - Card Content

    private var cardView: some View {
        Group {
            if let image = vm.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGray5))
                    .overlay(ProgressView().tint(.gray))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
    }

    // MARK: - Swipe Gesture

    private func swipeGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                isDragging = true
                withAnimation(.interactiveSpring(response: 0.3)) {
                    dragOffset   = value.translation
                    dragRotation = .degrees(Double(value.translation.width * rotationFactor))
                }

                // Velocity-aware lookahead
                let speed = hypot(value.velocity.width, value.velocity.height)
                Task { await provider.didAdvance(to: vm.currentIndex, velocity: Float(speed / 500)) }

                // Rugosidad háptica continua
                if !rugosityStarted, let profile = qualityProfile {
                    HapticAudioEngine.shared.startRugositySession(quality: profile)
                    rugosityStarted = true
                }
                if let profile = qualityProfile {
                    let progress = Float(min(abs(value.translation.width) / velocityThreshold, 1.0))
                    HapticAudioEngine.shared.updateRugosity(
                        dragProgress: progress, quality: profile
                    )
                }
            }
            .onEnded { value in
                isDragging      = false
                rugosityStarted = false
                HapticAudioEngine.shared.endRugositySession()

                let velocity = value.velocity
                let speed    = hypot(velocity.width, velocity.height)

                if speed > velocityThreshold {
                    handleDestructiveSwipe(velocity: velocity)
                } else {
                    snapBack()
                }
            }
    }

    // MARK: - Intent Predictor Setup

    private func setupIntentPredictor() {
        HapticAudioEngine.shared.prepare()

        Task {
            await predictor.configure(
                onIntentDetected: { [provider, vm] in
                    // Pre-calentar VRAM y haptics
                    HapticAudioEngine.shared.prime()

                    // Pre-cargar textura en el shredder (si hay asset visible)
                    let currentIdx = await MainActor.run { vm.currentIndex }
                    let assets     = await MainActor.run { vm.assets }
                    guard let asset = assets[safe: currentIdx] else { return }

                    if let texture = await provider.loadTexture(for: asset) {
                        let frame = await MainActor.run { cardGlobalFrame }
                        await MainActor.run {
                            GlobalShredderManager.shared.prepare(texture: texture, from: frame)
                        }
                    }
                },
                onIntentCancelled: nil
            )
            await predictor.startMonitoring()
        }
    }

    // MARK: - Quality Profile Computation

    private func computeQualityProfile() async {
        guard let asset = vm.assets[safe: vm.currentIndex] else { return }
        if let texture = await provider.loadTexture(for: asset) {
            let profile = PhotoQualityProfile.from(texture: texture)
            await MainActor.run { qualityProfile = profile }
        }
    }

    // MARK: - Destruction Dispatch (agnóstico de fuente)

    private func handleDestructiveSwipe(velocity: CGSize) {
        if thermal.thermalState == .critical {
            handleCriticalFallback()
            return
        }

        let norm = CGVector(
            dx: velocity.width  / velocityThreshold,
            dy: velocity.height / velocityThreshold
        )

        Task {
            guard vm.assets.indices.contains(vm.currentIndex) else { return }

            let targetSize = UIScreen.main.bounds.size
            let asset = vm.assets[vm.currentIndex]
            let texture = await provider.loadTexture(for: asset, targetSize: targetSize)

            await MainActor.run {
                // 1. Ocultar carta SwiftUI
                withAnimation(.easeOut(duration: 0.05)) { cardOpacity = 0 }

                // 2. Metal shredder — UX idéntica para Apple y Google
                if let texture {
                    GlobalShredderManager.shared.triggerExplosion(
                        texture: texture, from: cardGlobalFrame, velocity: norm
                    )
                }

                // 3. Haptic + Audio con EQ audio-reactiva
                HapticAudioEngine.shared.triggerDestruction(profile: qualityProfile)
            }

            // 4. Delegar al ViewModel: él decide delete (Apple) o enqueue (Google)
            await vm.processDecision(.destroy)

            // 5. Restaurar carta + recomputar perfil del nuevo asset
            await MainActor.run {
                dragOffset   = .zero
                dragRotation = .zero
                cardOpacity  = 1
            }
            await computeQualityProfile()
        }
    }

    // MARK: - Critical Thermal Fallback (sin Metal, sin audio, sin hápticos)

    private func handleCriticalFallback() {
        withAnimation(.easeOut(duration: 0.35)) {
            criticalScale   = 0.05
            criticalOpacity = 0
        }

        Task {
            try? await Task.sleep(for: .seconds(0.3))

            // Delegar al ViewModel (misma ruta que el flujo normal)
            await vm.processDecision(.destroy)

            await MainActor.run {
                dragOffset      = .zero
                dragRotation    = .zero
                criticalScale   = 1
                criticalOpacity = 1
            }
            await computeQualityProfile()
        }
    }

    // MARK: - Snap Back

    private func snapBack() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            dragOffset   = .zero
            dragRotation = .zero
        }
        Task { await provider.didAdvance(to: vm.currentIndex, velocity: 0) }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
