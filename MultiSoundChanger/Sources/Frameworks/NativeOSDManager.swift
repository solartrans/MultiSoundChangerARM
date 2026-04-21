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
    case speaker = 3
    case speakerMuted = 4
}

// Native OSD Manager implementation using a single reusable NSWindow
@objc
class OSDManager: NSObject {
    private static let instance = OSDManager()
    private var osdWindow: OSDWindow?

    @objc
    static func sharedManager() -> OSDManager {
        return instance
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
        guard let targetScreen = resolveScreen(for: displayID) else {
            Logger.warning("OSD: no NSScreen available, skipping show")
            return
        }

        let window: OSDWindow
        if let existing = osdWindow {
            window = existing
        } else {
            window = OSDWindow()
            osdWindow = window
        }

        window.update(
            graphic: graphic,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets,
            screen: targetScreen
        )
        window.show(fadeAfter: fadeDelay)
    }

    private func resolveScreen(for displayID: CGDirectDisplayID) -> NSScreen? {
        let matched = NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenNumber == displayID
        }

        if matched == nil {
            Logger.warning("OSD: no NSScreen matches displayID=\(displayID); using NSScreen.main")
        }

        return matched ?? NSScreen.main
    }
}

// Reusable OSD window — created once and updated in place for each volume event.
private final class OSDWindow: NSWindow {
    private static let windowSize = NSSize(width: 200, height: 200)

    private let contentPanel: OSDContentView
    private var fadeTimer: Timer?

    init() {
        contentPanel = OSDContentView(
            graphic: .speaker,
            filledChiclets: 0,
            totalChiclets: Constants.chicletsCount
        )

        let rect = NSRect(origin: .zero, size: OSDWindow.windowSize)

        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .statusBar
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.isReleasedWhenClosed = false
        self.contentView = contentPanel
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.animationBehavior = .utilityWindow
    }

    deinit {
        cleanup()
    }

    func update(graphic: OSDGraphic, filledChiclets: Int, totalChiclets: Int, screen: NSScreen) {
        contentPanel.update(
            graphic: graphic,
            filledChiclets: filledChiclets,
            totalChiclets: totalChiclets
        )
        repositionOn(screen: screen)
    }

    func show(fadeAfter delay: TimeInterval) {
        fadeTimer?.invalidate()
        fadeTimer = nil

        self.alphaValue = 1.0
        self.orderFrontRegardless()

        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    func cleanup() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        self.orderOut(nil)
    }

    private func repositionOn(screen: NSScreen) {
        let size = OSDWindow.windowSize
        // Use visibleFrame so the OSD respects the menu bar / dock instead of potentially
        // overlapping either on the primary display.
        let frame = screen.visibleFrame
        let xPos = frame.midX - size.width / 2
        let yPos = frame.midY + frame.height / 4 - size.height / 2
        self.setFrameOrigin(NSPoint(x: xPos, y: yPos))
    }

    private func fadeOut() {
        fadeTimer?.invalidate()
        fadeTimer = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

// Content view that draws the OSD. Values are mutable so the parent window can be reused.
private final class OSDContentView: NSView {
    private var graphic: OSDGraphic
    private var filledChiclets: Int
    private var totalChiclets: Int

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

    func update(graphic: OSDGraphic, filledChiclets: Int, totalChiclets: Int) {
        self.graphic = graphic
        self.filledChiclets = filledChiclets
        self.totalChiclets = totalChiclets
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundRect = bounds.insetBy(dx: 20, dy: 20)
        let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 20, yRadius: 20)

        NSColor.black.withAlphaComponent(0.8).setFill()
        backgroundPath.fill()

        drawIcon(in: backgroundRect)
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

        if graphic == .speakerMuted {
            drawSpeakerShape(in: iconRect)
            drawMuteX(in: iconRect)
        } else {
            drawSpeakerShape(in: iconRect)
            drawSoundWaves(in: iconRect)
        }
    }

    private func drawSpeakerShape(in rect: NSRect) {
        let path = NSBezierPath()

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
