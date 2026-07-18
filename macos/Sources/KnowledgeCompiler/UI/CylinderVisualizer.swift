import SceneKit
import SwiftUI

struct ForestTreeEntry {
    let id: UUID
    let title: String
    let nodeCount: Int
    let edgeCount: Int
    let species: TreeSpecies
}

enum TreeSpecies {
    case birch, cedar, beech, ash
    var tint: SIMD3<Float> {  // RGB tint for bark
        switch self {
        case .birch: return SIMD3(1.0, 1.0, 1.0)
        case .cedar: return SIMD3(1.0, 0.85, 0.72)
        case .beech: return SIMD3(1.0, 0.95, 0.88)
        case .ash:   return SIMD3(0.88, 0.86, 0.84)
        }
    }
    var knotTint: NSColor {
        switch self {
        case .birch: return NSColor(red: 0.24, green: 0.15, blue: 0.09, alpha: 1)
        case .cedar: return NSColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1)
        case .beech: return NSColor(red: 0.20, green: 0.13, blue: 0.08, alpha: 1)
        case .ash:   return NSColor(red: 0.18, green: 0.14, blue: 0.11, alpha: 1)
        }
    }
}

final class CylinderCoordinator: NSObject, ObservableObject {
    private let scene: SCNScene
    private let cameraNode: SCNNode
    private let treePivot: SCNNode
    private var trunkNode: SCNNode?
    private var rootNodes: [SCNNode] = []
    private var nodeSpheres: [SCNNode] = []
    private var edgeLines: [SCNNode] = []

    private var rotationVelocity: CGFloat = 0
    private var lastPanX: CGFloat = 0
    private var panStartTime: Date = Date()
    private var displayLink: CVDisplayLink?
    private var activeRotation: CGFloat = 0
    private var textureGenerationTask: Task<Void, Never>?

    private var nodeTitles: [String: String] = [:]
    private var hoverLabel: NSTextField?
    private var localMouseMonitor: Any?

    private let treeHeight: Float = 6.0
    private let baseRadius: Float = 3.0
    private let topRadius: Float = 2.0
    private let rotationsPerHeight: Float = 3.0

    private var currentSpecies: TreeSpecies = .birch
    var forestTrees: [ForestTreeEntry] = []
    private var currentMode: ViewMode = .forest
    private var lastMode: ViewMode = .forest

    private enum ViewMode { case forest, tree }

    private let forestCameraZ: Float = 18.0
    private let treeCameraZ: Float = 8.5

    private var scrollMonitor: Any?
    private var treeVerticalOffset: CGFloat = 0
    private let verticalSpeedThreshold: CGFloat = 400

    private var isAttached = false
    private var knownNodeIDs: Set<String> = []
    private var knownEdgePairs: Set<String> = []

    var onSelectNode: ((String) -> Void)?
    var onSelectForestTree: ((UUID) -> Void)?
    var onHoverNode: ((String?) -> Void)?
    var scnView: SCNView?

    override init() {
        scene = SCNScene()
        scene.background.contents = NSColor.clear

        cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zFar = 1000
        cameraNode.camera?.fieldOfView = 40
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.exposureOffset = -0.3
        cameraNode.position = SCNVector3(0, 0.3, forestCameraZ)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(white: 0.35, alpha: 1)
        ambient.light?.intensity = 600
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = NSColor(red: 1, green: 0.96, blue: 0.84, alpha: 1)
        key.light?.intensity = 1400
        key.position = SCNVector3(4, 6, 8)
        key.look(at: SCNVector3(0, 0, 0))
        key.light?.castsShadow = true
        key.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.light?.shadowRadius = 3
        key.light?.shadowSampleCount = 16
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.color = NSColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1)
        fill.light?.intensity = 350
        fill.position = SCNVector3(-3, -1, 4)
        scene.rootNode.addChildNode(fill)

        treePivot = SCNNode()
        scene.rootNode.addChildNode(treePivot)

        super.init()

        buildTrunk()
        buildRoots()
    }

    // MARK: - Tree geometry

    private func buildTrunk() {
        trunkNode?.removeFromParentNode()
        let cylinder = SCNCylinder(radius: CGFloat(baseRadius), height: CGFloat(treeHeight))
        cylinder.radialSegmentCount = 192
        cylinder.heightSegmentCount = 48

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1)
        material.roughness.contents = NSColor(white: 0.55, alpha: 1)
        material.metalness.contents = NSColor(white: 0, alpha: 1)
        material.diffuse.intensity = 1.0
        material.roughness.intensity = 1.0
        material.isDoubleSided = false
        material.transparencyMode = .aOne
        material.diffuse.maxAnisotropy = 16
        material.roughness.maxAnisotropy = 16
        cylinder.materials = [material]

        trunkNode = SCNNode(geometry: cylinder)
        trunkNode?.position = SCNVector3(0, 0, 0)
        treePivot.addChildNode(trunkNode!)
    }

    private func buildRoots() {
        rootNodes.forEach { $0.removeFromParentNode() }
        rootNodes.removeAll()
        let rootCount = 8
        let rootSpread: Float = 3.0
        let rootDepth: Float = 2.5
        for i in 0..<rootCount {
            let angle = Float(i) / Float(rootCount) * Float.pi * 2
            let sx = cos(angle) * baseRadius
            let sz = sin(angle) * baseRadius
            let ex = cos(angle) * (baseRadius + rootSpread)
            let ez = sin(angle) * (baseRadius + rootSpread)
            let start = SCNVector3(sx, -treeHeight / 2, sz)
            let mid = SCNVector3(ex * 0.6, -treeHeight / 2 - rootDepth * 0.5, ez * 0.6)
            let end = SCNVector3(ex, -treeHeight / 2 - rootDepth, ez)

            let source = SCNGeometrySource(vertices: [start, mid, end])
            let indices: [Int32] = [0, 1, 1, 2]
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geo = SCNGeometry(sources: [source], elements: [element])
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.diffuse.contents = NSColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 1)
            mat.isDoubleSided = true
            geo.materials = [mat]
            let node = SCNNode(geometry: geo)
            treePivot.addChildNode(node)
            rootNodes.append(node)
        }
    }

    func attach(to scnView: SCNView) {
        guard !isAttached else { return }
        isAttached = true

        scnView.scene = scene
        scnView.backgroundColor = .clear
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X
        scnView.isJitteringEnabled = true
        self.scnView = scnView

        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        scnView.addGestureRecognizer(pan)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        scnView.addGestureRecognizer(click)

        setupHoverLabel(for: scnView)
        setupMouseMonitor(for: scnView)
        setupScrollMonitor(for: scnView)

        startDisplayLink()
        generateTextures()
    }

    private func setupScrollMonitor(for view: SCNView) {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak view] event in
            guard let self, let view, let window = view.window, window.isKeyWindow else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return event }
            self.treeVerticalOffset -= event.scrollingDeltaY * 0.05
            self.treeVerticalOffset = max(self.treeVerticalOffset, -CGFloat(self.treeHeight / 2))
            self.treeVerticalOffset = min(self.treeVerticalOffset, CGFloat(self.treeHeight / 2))
            self.treePivot.position.y = self.treeVerticalOffset
            return event
        }
    }

    // MARK: - Camera zoom

    func zoomToTree(animated: Bool = true) {
        guard currentMode != .tree else { return }
        lastMode = currentMode
        currentMode = .tree
        trunkNode?.isHidden = false
        rootNodes.forEach { $0.isHidden = false }
        hideForestTrees()
        let targetZ = CGFloat(treeCameraZ)
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 2.5
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cameraNode.position.z = targetZ
            SCNTransaction.commit()
        } else {
            cameraNode.position.z = targetZ
        }
    }

    func zoomToForest(animated: Bool = true) {
        guard currentMode != .forest else { return }
        lastMode = currentMode
        currentMode = .forest
        knownNodeIDs.removeAll()
        knownEdgePairs.removeAll()
        trunkNode?.isHidden = true
        rootNodes.forEach { $0.isHidden = true }
        let targetZ = CGFloat(forestCameraZ)
        treePivot.eulerAngles.y = 0
        treePivot.position.y = 0
        treeVerticalOffset = 0
        activeRotation = 0
        rotationVelocity = 0
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 2.0
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cameraNode.position.z = targetZ
            SCNTransaction.commit()
        } else {
            cameraNode.position.z = targetZ
        }
    }

    private func hideForestTrees() {
        for child in treePivot.childNodes {
            let name = child.name ?? ""
            if name.hasPrefix("forest_") || name.hasPrefix("_label") {
                child.removeFromParentNode()
            }
        }
    }

    // MARK: - Sound propagation via ascend/descend

    private let helixWraps: Float = 3.0  // full rotations to cover the tree height
    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPanX = 0
            rotationVelocity = 0
            panStartTime = Date()
        case .changed:
            let dx = gesture.translation(in: gesture.view).x
            let dy = gesture.translation(in: gesture.view).y
            let delta = (dx - lastPanX) * 0.008
            lastPanX = dx
            activeRotation += delta
            treePivot.eulerAngles.y += delta

            let velocity = CGVector(dx: gesture.velocity(in: gesture.view).x, dy: gesture.velocity(in: gesture.view).y)
            let speed = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
            if speed > verticalSpeedThreshold {
                let verticalDelta = dy * 0.005
                treeVerticalOffset += verticalDelta
                treeVerticalOffset = max(treeVerticalOffset, -CGFloat(treeHeight / 2))
                treeVerticalOffset = min(treeVerticalOffset, CGFloat(treeHeight / 2))
                treePivot.position.y = treeVerticalOffset
            }
        case .ended, .cancelled:
            let elapsed = Date().timeIntervalSince(panStartTime)
            if elapsed > 0.01 {
                let totalDX = gesture.translation(in: gesture.view).x
                rotationVelocity = totalDX * 0.008 / CGFloat(elapsed)
            }
        default:
            break
        }
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        guard let view = gesture.view as? SCNView else { return }
        let point = gesture.location(in: view)
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        for hit in hits {
            if let nodeID = hit.node.name, !nodeID.hasPrefix("_"), !nodeID.isEmpty {
                if nodeID.hasPrefix("forest_"), let uuid = UUID(uuidString: String(nodeID.dropFirst(7))) {
                    onSelectForestTree?(uuid)
                } else {
                    onSelectNode?(nodeID)
                }
                break
            }
        }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, ctx) -> CVReturn in
            let coordinator = Unmanaged<CylinderCoordinator>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { coordinator.tick() }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    func tick() {
        if abs(rotationVelocity) > 0.0005 {
            activeRotation += rotationVelocity * 0.016
            treePivot.eulerAngles.y += rotationVelocity * 0.016
            rotationVelocity *= 0.97
        }
    }

    deinit {
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        textureGenerationTask?.cancel()
        if let link = displayLink { CVDisplayLinkStop(link) }
    }

    // MARK: - Hover label

    private func setupHoverLabel(for view: SCNView) {
        let label = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        label.textColor = NSColor(red: 0.9, green: 0.85, blue: 0.7, alpha: 1)
        label.font = NSFont(name: "AvenirNext-Regular", size: 12)
        label.alignment = .center
        label.isHidden = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        view.addSubview(label)
        hoverLabel = label
    }

    private func setupMouseMonitor(for view: SCNView) {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self, weak view] event in
            guard let self, let view, let window = view.window, window.isKeyWindow else { return event }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else {
                self.hoverLabel?.isHidden = true; self.onHoverNode?(nil); return event
            }
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            var hoveredID: String?
            for hit in hits {
                if let nodeID = hit.node.name, !nodeID.hasPrefix("_"), !nodeID.isEmpty {
                    hoveredID = nodeID; break
                }
            }
            if let id = hoveredID, let title = self.nodeTitles[id] {
                self.hoverLabel?.stringValue = title
                self.hoverLabel?.isHidden = false
                let w = min(CGFloat(title.count) * 7 + 20, 240)
                self.hoverLabel?.frame = NSRect(x: point.x - w / 2, y: view.bounds.height - point.y - 36, width: w, height: 22)
                self.onHoverNode?(id)
            } else {
                self.hoverLabel?.isHidden = true; self.onHoverNode?(nil)
            }
            return event
        }
    }

    // MARK: - 4K textures (async background generation)

    private func generateTextures() {
        textureGenerationTask?.cancel()
        let tint = currentSpecies.tint
        textureGenerationTask = Task(priority: .userInitiated) { [weak self] in
            let size = 4096
            let albedo = await Self.generateAlbedoMapAsync(width: size, height: size, tint: tint)
            let roughness = await Self.generateRoughnessMapAsync(width: size, height: size)
            let normal = await Self.generateNormalMapAsync(width: size, height: size)
            let ao = await Self.generateAOMapAsync(width: size, height: size)
            let displacement = await Self.generateDisplacementMapAsync(width: 1024, height: 1024)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, let mat = self.trunkNode?.geometry?.firstMaterial else { return }
                mat.diffuse.contents = albedo
                mat.roughness.contents = roughness
                mat.normal.contents = normal
                mat.ambientOcclusion.contents = ao
                mat.displacement.contents = displacement
                mat.displacement.intensity = 0.15
                mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
                mat.roughness.wrapS = .repeat; mat.roughness.wrapT = .repeat
                mat.normal.wrapS = .repeat; mat.normal.wrapT = .repeat
                mat.ambientOcclusion.wrapS = .repeat; mat.ambientOcclusion.wrapT = .repeat
                mat.displacement.wrapS = .repeat; mat.displacement.wrapT = .repeat
                mat.diffuse.maxAnisotropy = 16; mat.roughness.maxAnisotropy = 16
            }
        }
    }

    // MARK: - Node population (helical scaffold)

    func populate(nodes: [PageNode], edges: [GraphEdge], species: TreeSpecies = .birch, fullRebuild: Bool = false) {
        if fullRebuild {
            nodeSpheres.forEach { $0.removeFromParentNode() }
            edgeLines.forEach { $0.removeFromParentNode() }
            nodeSpheres.removeAll()
            edgeLines.removeAll()
            nodeTitles.removeAll()
            knownNodeIDs.removeAll()
            knownEdgePairs.removeAll()
        }
        hideForestTrees()
        trunkNode?.isHidden = false
        rootNodes.forEach { $0.isHidden = false }
        if fullRebuild || currentSpecies != species {
            currentSpecies = species
            generateTextures()
        }

        let count = max(nodes.count, 1)
        let halfH = treeHeight / 2
        let bandBottom = CGFloat(-halfH)
        let bandTop = CGFloat(-halfH + treeHeight / 3)

        var nodePositions: [String: SCNVector3] = [:]
        for (idx, node) in nodes.enumerated() {
            let frac = CGFloat(idx) / CGFloat(count)
            let theta = frac * CGFloat.pi * 2
            let depthFrac = CGFloat(min(node.depth, 3)) / 3.0
            let y = bandBottom + depthFrac * (bandTop - bandBottom)
            let radius = CGFloat(baseRadius) + (CGFloat(topRadius) - CGFloat(baseRadius)) * depthFrac + 0.28
            let x = radius * cos(theta)
            let z = radius * sin(theta)
            nodePositions[node.id] = SCNVector3(x, y, z)
            let short = node.title.lowercased()
            nodeTitles[node.id] = short.count > 50 ? String(short.prefix(47)) + "..." : short
        }

        // semantic adjustment — pull connected nodes slightly closer in theta
        var thetaAdjust: [String: CGFloat] = [:]
        for edge in edges {
            guard let a = nodePositions[edge.source], let b = nodePositions[edge.target] else { continue }
            let ta = atan2(a.z, a.x)
            let tb = atan2(b.z, b.x)
            var diff = tb - ta
            if diff > CGFloat.pi { diff -= 2 * CGFloat.pi }
            if diff < -CGFloat.pi { diff += 2 * CGFloat.pi }
            let pull = diff * 0.15
            thetaAdjust[edge.source, default: 0] += pull * 0.5
            thetaAdjust[edge.target, default: 0] -= pull * 0.5
        }

        for (id, adjust) in thetaAdjust {
            guard let pos = nodePositions[id] else { continue }
            let depthFrac = (pos.y - bandBottom) / (bandTop - bandBottom)
            let radius = CGFloat(baseRadius) + (CGFloat(topRadius) - CGFloat(baseRadius)) * depthFrac + 0.28
            let theta = atan2(pos.z, pos.x) + adjust
            nodePositions[id] = SCNVector3(radius * cos(theta), pos.y, radius * sin(theta))
        }

        let knotColors: [NSColor] = [
            NSColor(red: 0.83, green: 0.63, blue: 0.09, alpha: 1),  // mustard
            NSColor(red: 0.18, green: 0.55, blue: 0.55, alpha: 1),  // teal
            NSColor(red: 0.91, green: 0.45, blue: 0.29, alpha: 1),  // coral
            NSColor(red: 0.42, green: 0.56, blue: 0.14, alpha: 1),  // olive
            NSColor(red: 0.80, green: 0.33, blue: 0.00, alpha: 1),  // burnt orange
            NSColor(red: 0.55, green: 0.27, blue: 0.07, alpha: 1),  // warm brown
            NSColor(red: 0.73, green: 0.26, blue: 0.07, alpha: 1),  // rust
            NSColor(red: 0.25, green: 0.88, blue: 0.82, alpha: 1),  // turquoise
            NSColor(red: 0.34, green: 0.51, blue: 0.01, alpha: 1),  // avocado
            NSColor(red: 0.55, green: 0.20, blue: 0.45, alpha: 1),  // plum
        ]

        // incremental: only create geometry for new nodes
        for node in nodes {
            guard !knownNodeIDs.contains(node.id) else { continue }
            guard let pos = nodePositions[node.id] else { continue }
            knownNodeIDs.insert(node.id)
            let size = CGFloat(0.06 + min(CGFloat(node.chars) * 0.000005, 0.45))
            let knot = createKnot(radius: size, color: knotColors[Int(abs(pos.y * 7931 + pos.x * 6271)) % knotColors.count])
            knot.position = pos
            knot.name = node.id
            treePivot.addChildNode(knot)
            nodeSpheres.append(knot)
        }

        // incremental: only create geometry for new edges
        for edge in edges {
            let pairKey = "\(edge.source)→\(edge.target)"
            guard !knownEdgePairs.contains(pairKey) else { continue }
            knownEdgePairs.insert(pairKey)
            guard let start = nodePositions[edge.source], let end = nodePositions[edge.target] else { continue }
            let mid = SCNVector3(
                (start.x + end.x) / 2,
                (start.y + end.y) / 2,
                (start.z + end.z) / 2 + 0.6
            )
            let points = bezierPoints(from: start, through: mid, to: end, segments: 8)
            let edgeNode = smoothTendril(points: points)
            treePivot.addChildNode(edgeNode)
            edgeLines.append(edgeNode)
        }
    }

    // MARK: - Forest view

    func showForest(trees: [ForestTreeEntry]) {
        clearNodes()
        hideForestTrees()
        forestTrees = trees
        currentMode = .forest
        trunkNode?.isHidden = true
        rootNodes.forEach { $0.isHidden = true }
        treePivot.eulerAngles.y = 0
        treePivot.position.y = 0
        activeRotation = 0
        rotationVelocity = 0
        let count = trees.count
        guard count > 0 else { return }
        let forestRadius: Float = 6.0
        for (i, tree) in trees.enumerated() {
            let angle = Float(i) / Float(count) * Float.pi * 2
            let x = forestRadius * cos(angle)
            let z = forestRadius * sin(angle)
            let height = Float(1.5 + min(Double(tree.nodeCount) * 0.05, 4.0))
            let base = Float(0.4 + min(Double(tree.nodeCount) * 0.01, 1.0))

            let miniCylinder = SCNCylinder(radius: CGFloat(base), height: CGFloat(height))
            miniCylinder.radialSegmentCount = 48
            let mat = SCNMaterial()
            mat.lightingModel = .physicallyBased
            let t = tree.species.tint
            mat.diffuse.contents = NSColor(red: CGFloat(t.x) * 0.9, green: CGFloat(t.y) * 0.88, blue: CGFloat(t.z) * 0.82, alpha: 1)
            mat.roughness.contents = NSColor(white: 0.55, alpha: 1)
            mat.metalness.contents = NSColor(white: 0, alpha: 1)
            miniCylinder.materials = [mat]

            let coneNode = SCNNode(geometry: miniCylinder)
            coneNode.position = SCNVector3(x, 0, z)
            coneNode.name = "forest_\(tree.id.uuidString)"
            treePivot.addChildNode(coneNode)

            let labelNode = createLabel(text: tree.title, at: SCNVector3(x, height / 2 + 0.4, z))
            treePivot.addChildNode(labelNode)
        }
    }

    private func createLabel(text: String, at position: SCNVector3) -> SCNNode {
        let short = text.count > 18 ? String(text.prefix(15)) + "…" : text
        let textGeom = SCNText(string: short, extrusionDepth: 0.05)
        textGeom.font = NSFont(name: "AvenirNext-Regular", size: 0.6)
        textGeom.flatness = 0.1
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(red: 0.85, green: 0.80, blue: 0.65, alpha: 1)
        mat.lightingModel = .constant
        textGeom.materials = [mat]
        let node = SCNNode(geometry: textGeom)
        node.position = position
        node.name = "_label"
        let (minBound, maxBound) = textGeom.boundingBox
        let width = maxBound.x - minBound.x
        node.position.x -= width / 2
        return node
    }

    func clearForest() {
        hideForestTrees()
        forestTrees.removeAll()
    }

    func clearNodes() {
        nodeSpheres.forEach { $0.removeFromParentNode() }
        edgeLines.forEach { $0.removeFromParentNode() }
        nodeSpheres.removeAll()
        edgeLines.removeAll()
        clearForest()
    }

    // MARK: - Geometry helpers

    private func bezierPoints(from start: SCNVector3, through mid: SCNVector3, to end: SCNVector3, segments: Int) -> [SCNVector3] {
        var pts: [SCNVector3] = []
        let sx = Double(start.x); let sy = Double(start.y); let sz = Double(start.z)
        let mx = Double(mid.x); let my = Double(mid.y); let mz = Double(mid.z)
        let ex = Double(end.x); let ey = Double(end.y); let ez = Double(end.z)
        for i in 0...segments {
            let t = Double(i) / Double(segments); let u = 1.0 - t
            pts.append(SCNVector3(
                Float(u * u * sx + 2 * u * t * mx + t * t * ex),
                Float(u * u * sy + 2 * u * t * my + t * t * ey),
                Float(u * u * sz + 2 * u * t * mz + t * t * ez)
            ))
        }
        return pts
    }

    private func smoothTendril(points: [SCNVector3]) -> SCNNode {
        let source = SCNGeometrySource(vertices: points)
        var indices: [Int32] = []
        for i in 0..<(points.count - 1) { indices.append(Int32(i)); indices.append(Int32(i + 1)) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geo = SCNGeometry(sources: [source], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = NSColor(red: 0.30, green: 0.18, blue: 0.10, alpha: 1)
        mat.isDoubleSided = true
        geo.materials = [mat]
        return SCNNode(geometry: geo)
    }

    private func createKnot(radius: CGFloat, color: NSColor) -> SCNNode {
        let geom = SCNSphere(radius: radius)
        geom.segmentCount = 24
        let mat = SCNMaterial()
        mat.lightingModel = .physicallyBased
        mat.diffuse.contents = color
        mat.roughness.contents = NSColor(white: 0.7, alpha: 1)
        mat.metalness.contents = NSColor(white: 0, alpha: 1)
        mat.ambientOcclusion.contents = NSColor(white: 0.6, alpha: 1)
        geom.materials = [mat]
        return SCNNode(geometry: geom)
    }

    // MARK: - PBR texture generation

    private static func fbm(x: Int, y: Int, octaves: Int, lacunarity: Double, gain: Double, seed: Int, scale: Double = 1.0) -> Double {
        var value: Double = 0; var amplitude: Double = 1; var freq: Double = 1; var maxVal: Double = 0
        for i in 0..<octaves {
            let fx = Double(x) * freq / scale; let fy = Double(y) * freq / scale
            let n = sin(fx * 12.9898 + fy * 78.233 + Double(seed + i * 127) * 437.58) * 43758.5453
            value += amplitude * (n - floor(n)); maxVal += amplitude; amplitude *= gain; freq *= lacunarity
        }
        return value / maxVal
    }

    private static func generateAlbedoMapAsync(width: Int, height: Int, tint: SIMD3<Float>) async -> NSImage {
        await Task(priority: .userInitiated) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            guard let ptr = rep.bitmapData else { return NSImage(size: NSSize(width: width, height: height)) }
            for y in 0..<height {
                let yFrac = Double(y) / Double(height)
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let bark = fbm(x: x, y: y, octaves: 6, lacunarity: 2.3, gain: 0.55, seed: 42, scale: 160.0)
                    let grain = sin(yFrac * .pi * 18.0 + bark * 3.0) * 0.5 + 0.5
                    let str = pow(grain, 9.0)
                    let vert = fbm(x: x, y: y * 3, octaves: 3, lacunarity: 1.8, gain: 0.5, seed: 99, scale: 300.0) * 0.07
                    let baseR = Double(tint.x) * (0.95 + (bark - 0.5) * 0.08 + vert)
                    let dark = str * 0.48
                    let micro = fbm(x: x * 3, y: y * 3, octaves: 3, lacunarity: 2.1, gain: 0.5, seed: 77, scale: 100.0) * 0.04
                    let r = max(0, min(1, baseR * (1 - dark) + 0.12 * dark + micro))
                    let g = max(0, min(1, Double(tint.y) * (0.91) * (1 - dark) + 0.06 * dark + micro))
                    let b = max(0, min(1, Double(tint.z) * (0.83) * (1 - dark) + 0.03 * dark + micro * 0.6))
                    let isKnot = (x * 47 + y * 73 + 127) % 1423 < 18 && bark > 0.35
                    ptr[o] = isKnot ? 18 : UInt8(r * 255); ptr[o+1] = isKnot ? 12 : UInt8(g * 255)
                    ptr[o+2] = isKnot ? 8 : UInt8(b * 255); ptr[o+3] = 255
                }
            }
            let img = NSImage(size: NSSize(width: width, height: height)); img.addRepresentation(rep); return img
        }.value
    }

    private static func generateRoughnessMapAsync(width: Int, height: Int) async -> NSImage {
        await Task(priority: .userInitiated) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            guard let ptr = rep.bitmapData else { return NSImage(size: NSSize(width: width, height: height)) }
            for y in 0..<height {
                let yFrac = Double(y) / Double(height)
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let bark = fbm(x: x, y: y, octaves: 4, lacunarity: 2.5, gain: 0.5, seed: 200, scale: 200.0)
                    let grain = sin(yFrac * .pi * 18.0 + bark * 2.0) * 0.5 + 0.5
                    let str = pow(grain, 7.0)
                    let base: Double = 0.6; let peel: Double = 0.25
                    let rough = base + (peel - base) * str
                    let micro = fbm(x: x * 2, y: y * 2, octaves: 2, lacunarity: 2.0, gain: 0.5, seed: 310, scale: 120.0) * 0.12
                    let v = UInt8(max(0, min(255, (rough + micro - bark * 0.06) * 255)))
                    ptr[o] = v; ptr[o+1] = v; ptr[o+2] = v; ptr[o+3] = 255
                }
            }
            let img = NSImage(size: NSSize(width: width, height: height)); img.addRepresentation(rep); return img
        }.value
    }

    private static func generateNormalMapAsync(width: Int, height: Int) async -> NSImage {
        await Task(priority: .userInitiated) {
            var hm = [[Double]](repeating: [Double](repeating: 0, count: width), count: height)
            for y in 0..<height {
                let yFrac = Double(y) / Double(height)
                for x in 0..<width {
                    let bark = fbm(x: x, y: y, octaves: 5, lacunarity: 2.3, gain: 0.55, seed: 42, scale: 160.0)
                    let grain = sin(yFrac * .pi * 18.0 + bark * 3.0) * 0.5 + 0.5
                    let str = pow(grain, 9.0)
                    let micro = fbm(x: x * 4, y: y * 4, octaves: 3, lacunarity: 2.0, gain: 0.5, seed: 600, scale: 60.0) * 0.1
                    hm[y][x] = str * 0.09 + micro
                }
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            guard let ptr = rep.bitmapData else { return NSImage(size: NSSize(width: width, height: height)) }
            let s: Double = 8.0
            for y in 0..<height {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let l = hm[y][(x-1+width)%width]; let r = hm[y][(x+1)%width]
                    let d = hm[(y-1+height)%height][x]; let u = hm[(y+1)%height][x]
                    let dx = (r-l)*s; let dy = (u-d)*s; let len = sqrt(dx*dx+dy*dy+1)
                    ptr[o] = UInt8(((dx/len)*0.5+0.5)*255); ptr[o+1] = UInt8(((dy/len)*0.5+0.5)*255)
                    ptr[o+2] = UInt8(((1.0/len)*0.5+0.5)*255); ptr[o+3] = 255
                }
            }
            let img = NSImage(size: NSSize(width: width, height: height)); img.addRepresentation(rep); return img
        }.value
    }

    private static func generateAOMapAsync(width: Int, height: Int) async -> NSImage {
        await Task(priority: .userInitiated) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            guard let ptr = rep.bitmapData else { return NSImage(size: NSSize(width: width, height: height)) }
            for y in 0..<height {
                let yFrac = Double(y) / Double(height)
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let bark = fbm(x: x, y: y, octaves: 4, lacunarity: 2.5, gain: 0.5, seed: 42, scale: 200.0)
                    let grain = sin(yFrac * .pi * 18.0 + bark * 3.0) * 0.5 + 0.5
                    let str = pow(grain, 9.0)
                    let micro = fbm(x: x * 3, y: y * 3, octaves: 3, lacunarity: 2.2, gain: 0.5, seed: 500, scale: 100.0) * 0.1
                    let v = UInt8(max(0, min(255, (0.9 - str * 0.5 + micro) * 255)))
                    ptr[o] = v; ptr[o+1] = v; ptr[o+2] = v; ptr[o+3] = 255
                }
            }
            let img = NSImage(size: NSSize(width: width, height: height)); img.addRepresentation(rep); return img
        }.value
    }

    private static func generateDisplacementMapAsync(width: Int, height: Int) async -> NSImage {
        await Task(priority: .userInitiated) {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
            guard let ptr = rep.bitmapData else { return NSImage(size: NSSize(width: width, height: height)) }
            for y in 0..<height {
                let yFrac = Double(y) / Double(height)
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    let bark = fbm(x: x, y: y, octaves: 6, lacunarity: 2.3, gain: 0.55, seed: 42, scale: 80.0)
                    let grain = sin(yFrac * .pi * 18.0 + bark * 3.0) * 0.5 + 0.5
                    let str = pow(grain, 9.0)
                    let pitting = fbm(x: x * 5, y: y * 5, octaves: 4, lacunarity: 2.0, gain: 0.5, seed: 900, scale: 30.0) * 0.15
                    var val = str * 0.7 + pitting + bark * 0.1
                    val = max(0, min(1, val))
                    let v = UInt8(val * 255)
                    ptr[o] = v; ptr[o+1] = v; ptr[o+2] = v; ptr[o+3] = 255
                }
            }
            let img = NSImage(size: NSSize(width: width, height: height)); img.addRepresentation(rep); return img
        }.value
    }
}

struct CylinderVisualizer: NSViewRepresentable {
    @ObservedObject var graph: GraphStore
    let onSelectNode: (String) -> Void
    var forestTrees: [ForestTreeEntry] = []
    var forestMode: Bool = false
    var onSelectForestTree: ((UUID) -> Void)?

    func makeCoordinator() -> CylinderCoordinator {
        CylinderCoordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.clear
        context.coordinator.attach(to: view)
        context.coordinator.onSelectNode = onSelectNode
        context.coordinator.onSelectForestTree = onSelectForestTree
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        let prevMode = context.coordinator.forestTrees.isEmpty && forestMode
        let prevForestCount = context.coordinator.forestTrees.count

        if forestMode {
            if prevForestCount == 0 || forestTrees.count != prevForestCount {
                context.coordinator.showForest(trees: forestTrees)
            }
            if !prevMode {
                context.coordinator.zoomToForest(animated: true)
            }
        } else {
            let needsRebuild = context.coordinator.forestTrees.isEmpty ? false : true
            if needsRebuild {
                context.coordinator.clearForest()
            }
            context.coordinator.populate(
                nodes: graph.nodes,
                edges: graph.edges,
                fullRebuild: needsRebuild
            )
            if prevMode {
                context.coordinator.zoomToTree(animated: true)
            }
        }
    }
}
