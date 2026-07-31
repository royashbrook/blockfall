import UIKit

final class PauseOverlay: UIView {
    var onResume: (() -> Void)?
    var onMode: (() -> Void)?
    var onHost: (() -> Void)?
    var onJoin: (() -> Void)?
    var onTouchSize: ((TouchControlSize) -> Void)?
    var onWorlds: (() -> Void)?
    var onGraphics: (() -> Void)?

    private let status = UILabel()
    private let touchSize = UISegmentedControl(items: TouchControlSize.allCases.map(\.title))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.02, alpha: 0.74)

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 0.98)
        card.layer.cornerRadius = 24
        card.layer.borderWidth = 3
        card.layer.borderColor = UIColor(red: 0.96, green: 0.72, blue: 0.28, alpha: 1).cgColor
        addSubview(card)

        let title = UILabel()
        title.text = "Blockfall is paused"
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 30)
        title.textAlignment = .center

        let instructions = UILabel()
        instructions.text =
            "Left thumb: move · Drag the world: look\n"
            + "Tap the world: use · Hold the world: mine or attack"
        instructions.textColor = UIColor.white.withAlphaComponent(0.78)
        instructions.font = .systemFont(ofSize: 16, weight: .semibold)
        instructions.textAlignment = .center
        instructions.numberOfLines = 0

        let touchSizeLabel = UILabel()
        touchSizeLabel.text = "Touch control size"
        touchSizeLabel.textColor = .white
        touchSizeLabel.font = .boldSystemFont(ofSize: 16)
        touchSize.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        touchSize.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        touchSize.selectedSegmentIndex = TouchControlSize.saved.rawValue
        touchSize.addTarget(self, action: #selector(touchSizeChanged), for: .valueChanged)
        let touchSizeRow = UIStackView(arrangedSubviews: [touchSizeLabel, touchSize])
        touchSizeRow.axis = .horizontal
        touchSizeRow.alignment = .center
        touchSizeRow.distribution = .fill
        touchSizeRow.spacing = 16
        touchSize.widthAnchor.constraint(equalToConstant: 230).isActive = true
        touchSize.heightAnchor.constraint(equalToConstant: 40).isActive = true

        status.textColor = UIColor.systemYellow
        status.font = .boldSystemFont(ofSize: 15)
        status.textAlignment = .center
        status.numberOfLines = 0

        let resume = makeButton("Resume", color: UIColor(red: 0.20, green: 0.64, blue: 0.42, alpha: 1))
        resume.addTarget(self, action: #selector(resumeTapped), for: .touchUpInside)
        let mode = makeButton("Toggle Creative / Survival", color: UIColor(red: 0.25, green: 0.50, blue: 0.84, alpha: 1))
        mode.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        let host = makeButton("Host Family Game", color: UIColor(red: 0.56, green: 0.36, blue: 0.76, alpha: 1))
        host.addTarget(self, action: #selector(hostTapped), for: .touchUpInside)
        let join = makeButton("Join Nearby Game", color: UIColor(red: 0.78, green: 0.48, blue: 0.22, alpha: 1))
        join.addTarget(self, action: #selector(joinTapped), for: .touchUpInside)
        let graphics = makeButton("Visual Settings", color: UIColor(red: 0.20, green: 0.56, blue: 0.64, alpha: 1))
        graphics.addTarget(self, action: #selector(graphicsTapped), for: .touchUpInside)
        let worlds = makeButton("Save & Choose World", color: UIColor(red: 0.42, green: 0.45, blue: 0.54, alpha: 1))
        worlds.addTarget(self, action: #selector(worldsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            title, instructions, touchSizeRow, resume, mode, host, join, graphics, worlds, status,
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 480),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -26),
            resume.heightAnchor.constraint(equalToConstant: 52),
            mode.heightAnchor.constraint(equalToConstant: 48),
            host.heightAnchor.constraint(equalToConstant: 48),
            join.heightAnchor.constraint(equalToConstant: 48),
            graphics.heightAnchor.constraint(equalToConstant: 48),
            worlds.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func showStatus(_ message: String) {
        status.text = message
    }

    private func makeButton(_ title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = color
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .boldSystemFont(ofSize: 17)
            return outgoing
        }
        button.configuration = config
        return button
    }

    @objc private func resumeTapped() { onResume?() }
    @objc private func modeTapped() { onMode?() }
    @objc private func hostTapped() { onHost?() }
    @objc private func joinTapped() { onJoin?() }
    @objc private func graphicsTapped() { onGraphics?() }
    @objc private func worldsTapped() { onWorlds?() }
    @objc private func touchSizeChanged() {
        guard let size = TouchControlSize(rawValue: touchSize.selectedSegmentIndex) else { return }
        onTouchSize?(size)
    }
}

/// Live iPad graphics controls backed by the same preferences as the Mac app.
final class GraphicsSettingsViewController: UIViewController {
    private weak var renderer: Renderer?
    private let onMinimapChanged: (Bool) -> Void

    init(renderer: Renderer, onMinimapChanged: @escaping (Bool) -> Void) {
        self.renderer = renderer
        self.onMinimapChanged = onMinimapChanged
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.055, green: 0.07, blue: 0.11, alpha: 1)

        let title = UILabel()
        title.text = "Visual Settings"
        title.textColor = .white
        title.font = .systemFont(ofSize: 32, weight: .black)
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Changes apply immediately and stay saved. Turn off heavier effects if the iPad gets warm."
        subtitle.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitle.font = .systemFont(ofSize: 15, weight: .semibold)
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0

        let done = UIButton(type: .system)
        var doneConfig = UIButton.Configuration.filled()
        doneConfig.title = "Done"
        doneConfig.baseBackgroundColor = .systemGreen
        doneConfig.baseForegroundColor = .white
        doneConfig.cornerStyle = .large
        done.configuration = doneConfig
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        done.widthAnchor.constraint(equalToConstant: 110).isActive = true
        done.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let header = UIStackView(arrangedSubviews: [title, subtitle, done])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        view.addSubview(scroll)

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        guard let renderer else { return }
        addToggle(to: content, title: "Waving foliage", detail: "Animated leaves and grass", key: "gfxFoliage", initial: renderer.gfxFoliage) {
            renderer.gfxFoliage = $0
        }
        addToggle(to: content, title: "Animated water", detail: "Ripples and flowing surfaces", key: "gfxWater", initial: renderer.gfxWater) {
            renderer.gfxWater = $0
        }
        addToggle(to: content, title: "God rays", detail: "Sunbeams through the world (heavier)", key: "gfxGodRays", initial: renderer.gfxGodRays) {
            renderer.gfxGodRays = $0
        }
        addToggle(to: content, title: "Pollen and motes", detail: "Tiny particles in the air", key: "gfxPollen", initial: renderer.gfxPollen) {
            renderer.gfxPollen = $0
        }
        addToggle(to: content, title: "World shadows", detail: "Terrain and building shadows", key: "gfxShadows", initial: renderer.gfxShadows) {
            renderer.gfxShadows = $0
        }
        addToggle(to: content, title: "Soft shadows", detail: "Softer edges (heavier)", key: "gfxSoftShadows", initial: renderer.gfxSoftShadows) {
            renderer.gfxSoftShadows = $0
        }
        addToggle(to: content, title: "Character shadows", detail: "Shadows below people and creatures", key: "gfxCharShadows", initial: renderer.gfxCharShadows) {
            renderer.gfxCharShadows = $0
        }
        addToggle(to: content, title: "Cel shading", detail: "Bold inked edges", key: "gfxCelShade", initial: renderer.gfxCelShade) {
            renderer.gfxCelShade = $0
        }
        addToggle(to: content, title: "Bloom", detail: "Glow around bright objects", key: "gfxBloom", initial: renderer.gfxBloom) {
            renderer.gfxBloom = $0
        }
        addToggle(to: content, title: "Lens flare", detail: "Cartoon flare near the sun", key: "gfxLensFlare", initial: renderer.gfxLensFlare) {
            renderer.gfxLensFlare = $0
        }
        addToggle(to: content, title: "Volumetric clouds", detail: "Full fluffy clouds (heavier)", key: "gfxClouds", initial: renderer.gfxClouds) {
            renderer.gfxClouds = $0
        }
        let minimapVisible = UserDefaults.standard.object(forKey: "minimap") as? Bool ?? true
        addToggle(to: content, title: "Minimap", detail: "Nearby places and your heading", key: "minimap", initial: minimapVisible) { [weak self] visible in
            self?.onMinimapChanged(visible)
        }

        let savedDistance = UserDefaults.standard.object(forKey: "gfxRenderDist") as? Int ?? 16
        addSlider(to: content, title: "Render distance", value: Float(savedDistance), range: 8...32, step: 1, suffix: " chunks") { value in
            let chunks = Int(value.rounded())
            UserDefaults.standard.set(chunks, forKey: "gfxRenderDist")
            renderer.setRenderDistance(chunks)
        }
        addSlider(to: content, title: "God-ray strength", value: renderer.gfxGodRayStr, range: 0...1, step: 0.05, suffix: "") { value in
            renderer.gfxGodRayStr = value
            UserDefaults.standard.set(Double(value), forKey: "gfxGodRayStr")
        }
        addSlider(to: content, title: "Bloom strength", value: renderer.gfxBloomStr, range: 0...1, step: 0.05, suffix: "") { value in
            renderer.gfxBloomStr = value
            UserDefaults.standard.set(Double(value), forKey: "gfxBloomStr")
        }
        addSlider(to: content, title: "Cel outline strength", value: renderer.gfxCelOutlineStr, range: 0...1, step: 0.05, suffix: "") { value in
            renderer.gfxCelOutlineStr = value
            UserDefaults.standard.set(Double(value), forKey: "gfxCelOutlineStr")
        }
        addSlider(to: content, title: "Material shine", value: renderer.gfxPBRStr, range: 0...1, step: 0.05, suffix: "") { value in
            renderer.gfxPBRStr = value
            UserDefaults.standard.set(Double(value), forKey: "gfxPBRStr")
        }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            header.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            header.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            scroll.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 720),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
    }

    private func addToggle(
        to stack: UIStackView,
        title: String,
        detail: String,
        key: String,
        initial: Bool,
        apply: @escaping (Bool) -> Void
    ) {
        let label = settingsLabel(title: title, detail: detail)
        let control = UISwitch()
        control.isOn = initial
        control.addAction(UIAction { [weak control] _ in
            guard let toggle = control else { return }
            UserDefaults.standard.set(toggle.isOn, forKey: key)
            apply(toggle.isOn)
        }, for: .valueChanged)
        let row = settingsRow([label, control])
        stack.addArrangedSubview(row)
    }

    private func addSlider(
        to stack: UIStackView,
        title: String,
        value: Float,
        range: ClosedRange<Float>,
        step: Float,
        suffix: String,
        apply: @escaping (Float) -> Void
    ) {
        let valueLabel = UILabel()
        valueLabel.textColor = UIColor.systemYellow
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        valueLabel.textAlignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 105).isActive = true

        let slider = UISlider()
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.value = value
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let update: (Float) -> Void = { raw in
            let stepped = (raw / step).rounded() * step
            valueLabel.text = step >= 1 ? "\(Int(stepped))\(suffix)" : "\(Int((stepped * 100).rounded()))%"
            apply(stepped)
        }
        update(value)
        slider.addAction(UIAction { [weak slider] _ in
            guard let slider else { return }
            update(slider.value)
        }, for: .valueChanged)

        let label = settingsLabel(title: title, detail: "")
        let row = settingsRow([label, slider, valueLabel])
        stack.addArrangedSubview(row)
    }

    private func settingsLabel(title: String, detail: String) -> UILabel {
        let label = UILabel()
        label.text = detail.isEmpty ? title : "\(title)\n\(detail)"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .bold)
        label.numberOfLines = 2
        if !detail.isEmpty {
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: UIColor.white,
            ])
            text.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.62),
            ]))
            label.attributedText = text
        }
        return label
    }

    private func settingsRow(_ views: [UIView]) -> UIView {
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        row.backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 0.98)
        row.layer.cornerRadius = 14
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        views.first?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    @objc private func doneTapped() { dismiss(animated: true) }
}

final class IPadWorldMapViewController: UIViewController {
    var onClose: (() -> Void)?

    private weak var renderer: Renderer?
    private let mapView = IPadWorldMapView()

    init(renderer: Renderer, snapshot: Renderer.MapSnapshot, biomes: [UInt8]) {
        self.renderer = renderer
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        mapView.snapshot = snapshot
        mapView.biomes = biomes
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.045, green: 0.055, blue: 0.09, alpha: 1)

        let title = UILabel()
        title.text = "World Map"
        title.textColor = .white
        title.font = .systemFont(ofSize: 32, weight: .black)
        title.textAlignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        let close = mapButton("Done", color: .systemGreen)
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(close)

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.onMarkerTapped = { [weak self] marker in self?.confirmTravel(to: marker) }
        view.addSubview(mapView)

        let zoomIn = mapButton("＋", color: .systemBlue)
        zoomIn.addTarget(self, action: #selector(zoomInTapped), for: .touchUpInside)
        let zoomOut = mapButton("−", color: .systemBlue)
        zoomOut.addTarget(self, action: #selector(zoomOutTapped), for: .touchUpInside)
        let zoomStack = UIStackView(arrangedSubviews: [zoomIn, zoomOut])
        zoomStack.axis = .vertical
        zoomStack.spacing = 14
        zoomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomStack)
        [zoomIn, zoomOut].forEach {
            $0.widthAnchor.constraint(equalToConstant: 58).isActive = true
            $0.heightAnchor.constraint(equalToConstant: 58).isActive = true
        }

        let hint = UILabel()
        hint.text = "Tap a place to travel · explored land is colored · dark land is still unknown"
        hint.textColor = UIColor.white.withAlphaComponent(0.72)
        hint.font = .systemFont(ofSize: 14, weight: .semibold)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            close.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 24),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 110),
            close.heightAnchor.constraint(equalToConstant: 46),

            mapView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            mapView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -4),
            mapView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            mapView.widthAnchor.constraint(equalTo: mapView.heightAnchor),
            mapView.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 100),
            mapView.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -100),

            zoomStack.leadingAnchor.constraint(equalTo: mapView.trailingAnchor, constant: 18),
            zoomStack.centerYAnchor.constraint(equalTo: mapView.centerYAnchor),
            hint.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func mapButton(_ title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = color
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 18, weight: .black)
            return outgoing
        }
        button.configuration = config
        return button
    }

    private func confirmTravel(to marker: MapView.Marker) {
        let alert = UIAlertController(
            title: marker.name,
            message: "Travel here now?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Stay Here", style: .cancel))
        alert.addAction(UIAlertAction(title: "Travel", style: .default) { [weak self] _ in
            guard let self else { return }
            if self.renderer?.mapTeleport(marker.id) == true {
                self.onClose?()
            } else {
                let error = UIAlertController(
                    title: "Could not travel",
                    message: "Try this marker again in a moment.",
                    preferredStyle: .alert
                )
                error.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(error, animated: true)
            }
        })
        present(alert, animated: true)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func zoomInTapped() { mapView.zoomIn() }
    @objc private func zoomOutTapped() { mapView.zoomOut() }
}
