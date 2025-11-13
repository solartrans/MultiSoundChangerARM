//
//  NativeOSDManager.swift
//  MultiSoundChanger
//
//  Native ARM64-compatible replacement for OSD.framework
//

import Cocoa
import Foundation

// OSD Graphics enum to match the original framework
@objc
enum OSDGraphic: Int {
    case backlight = 1
    case speaker = 3
    case speakerMuted = 4
    case eject = 6
    case noWiFi = 9
    case keyboardBacklightMeter = 11
    case keyboardBacklightDisabledMeter = 12
    case keyboardBacklightNotConnected = 13
    case keyboardBacklightDisabledNotConnected = 14
    case macProOpen = 15
    case hotspot = 19
    case sleep = 20
}

// Native OSD Manager implementation using NSWindow
@objc
class OSDManager: NSObject {
    private static var shared: OSDManager?
    private var osdWindow: OSDWindow?

    @objc
    static func sharedManager() -> OSDManager {
        if let existingManager = shared {
            return existingManager
        }
        let newManager = OSDManager()
        shared = newManager
        return newManager
    }

    private override init() {
        super.init()
    }

    @objc
    func showImage(
        _ image: Int64,
        onDisplayID displayID: CGDirectDisplayID,
        priority: UInt32,
        msecUntilFade: UInt32,
        filledChiclets: UInt32,
        totalChiclets: UInt32,
        locked: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.displayOSD(
                graphic: OSDGraphic(rawValue: Int(image)) ?? .speaker,
                displayID: displayID,
                filledChiclets: Int(filledChiclets),
                totalChiclets: Int(totalChiclets),
                fadeDelay: TimeInterval(msecUntilFade) / 1_000.0
            )
        }
    }

    private func displayOSD(
        graphic: OSDGraphic,
        displayID: CGDirectDisplayID,
        filledChiclets: Int,
        totalChiclets: Int,
        fadeDelay: TimeInterval
    ) {
        // Close existing window if any
        osdWindow?.close()

        // Get the screen for the display
        let screen = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == displayID
        } ?? NSScreen.main

        guard let targetScreen = screen else {
            return
        }

        // Create and show OSD window
        let window = OSDWindow(
            graphic: graphic,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets,
            screen: targetScreen
        )

        osdWindow = window
        window.show(fadeAfter: fadeDelay)
    }
}

// Custom window to display OSD
private class OSDWindow: NSWindow {
    private let contentPanel: NSView
    private var fadeTimer: Timer?

    init(graphic: OSDGraphic, filledChiclets: Int, totalChiclets: Int, screen: NSScreen) {
        // Window dimensions
        let windowWidth: CGFloat = 200
        let windowHeight: CGFloat = 200

        // Center on screen
        let screenFrame = screen.frame
        let xPos = screenFrame.midX - windowWidth / 2
        let yPos = screenFrame.midY + screenFrame.height / 4 - windowHeight / 2

        let rect = NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight)

        // Create content view
        contentPanel = OSDContentView(
            graphic: graphic,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets
        )

        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // Window configuration
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.contentView = contentPanel
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.animationBehavior = .utilityWindow

        // Position on the correct screen
        if let currentScreen = NSScreen.screens.first(where: { $0 == screen }) {
            self.setFrameOrigin(NSPoint(x: xPos, y: yPos))
        }
    }

    func show(fadeAfter delay: TimeInterval) {
        self.alphaValue = 0
        self.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1.0
        }

        // Schedule fade out
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.animator().alphaValue = 0
        }, completionHandler: {
            self.close()
        })
    }
}

// Content view that draws the OSD
private class OSDContentView: NSView {
    private let graphic: OSDGraphic
    private let filledChiclets: Int
    private let totalChiclets: Int

    init(graphic: OSDGraphic, filledChiclets: Int, totalChiclets: Int) {
        self.graphic = graphic
        self.filledChiclets = filledChiclets
        self.totalChiclets = totalChiclets
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        _ = NSGraphicsContext.current?.cgContext

        // Draw background rounded rectangle
        let backgroundRect = bounds.insetBy(dx: 20, dy: 20)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 20, yRadius: 20)

        NSColor.black.withAlphaComponent(0.8).setFill()
        backgroundPath.fill()

        // Draw icon
        drawIcon(in: backgroundRect)

        // Draw chiclets (volume bars)
        drawChiclets(in: backgroundRect)
    }

    private func drawIcon(in rect: NSRect) {
        let iconSize: CGFloat = 40
        let iconRect = NSRect(
            x: rect.midX - iconSize / 2,
            y: rect.maxY - iconSize - 30,
            width: iconSize,
            height: iconSize
        )

        NSColor.white.setFill()

        // Draw speaker icon (simplified)
        if graphic == .speakerMuted {
            // Draw muted speaker with X
            drawSpeakerShape(in: iconRect)
            drawMuteX(in: iconRect)
        } else {
            // Draw normal speaker
            drawSpeakerShape(in: iconRect)
            drawSoundWaves(in: iconRect)
        }
    }

    private func drawSpeakerShape(in rect: NSRect) {
        let path = NSBezierPath()

        // Speaker cone (simplified trapezoid shape)
        let coneRect = NSRect(
            x: rect.minX + rect.width * 0.2,
            y: rect.minY + rect.height * 0.3,
            width: rect.width * 0.3,
            height: rect.height * 0.4
        )

        path.move(to: NSPoint(x: coneRect.minX, y: coneRect.minY))
        path.line(to: NSPoint(x: coneRect.maxX, y: coneRect.minY + coneRect.height * 0.2))
        path.line(to: NSPoint(x: coneRect.maxX, y: coneRect.maxY - coneRect.height * 0.2))
        path.line(to: NSPoint(x: coneRect.minX, y: coneRect.maxY))
        path.close()

        NSColor.white.setFill()
        path.fill()
    }

    private func drawSoundWaves(in rect: NSRect) {
        let startX = rect.maxX - rect.width * 0.35
        let centerY = rect.midY

        for i in 1...3 {
            let arc = NSBezierPath()
            let radius = CGFloat(i) * 5
            arc.appendArc(
                withCenter: NSPoint(x: startX, y: centerY),
                radius: radius,
                startAngle: -30,
                endAngle: 30
            )

            NSColor.white.setStroke()
            arc.lineWidth = 2
            arc.stroke()
        }
    }

    private func drawMuteX(in rect: NSRect) {
        let xPath = NSBezierPath()
        let inset: CGFloat = rect.width * 0.25

        xPath.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        xPath.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        xPath.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        xPath.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))

        NSColor.red.setStroke()
        xPath.lineWidth = 3
        xPath.stroke()
    }

    private func drawChiclets(in rect: NSRect) {
        guard totalChiclets > 0 else {
            return
        }

        let chicletAreaWidth = rect.width - 60
        let chicletAreaHeight: CGFloat = 8
        let chicletSpacing: CGFloat = 2
        let chicletWidth = (chicletAreaWidth - CGFloat(totalChiclets - 1) * chicletSpacing) / CGFloat(totalChiclets)

        let startX = rect.minX + 30
        let startY = rect.minY + 40

        for i in 0..<totalChiclets {
            let xPos = startX + CGFloat(i) * (chicletWidth + chicletSpacing)
            let chicletRect = NSRect(x: xPos, y: startY, width: chicletWidth, height: chicletAreaHeight)

            let chicletPath = NSBezierPath(roundedRect: chicletRect, xRadius: 2, yRadius: 2)

            if i < filledChiclets {
                NSColor.white.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.3).setFill()
            }

            chicletPath.fill()
        }
    }
}
