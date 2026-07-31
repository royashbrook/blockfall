import UIKit

final class PauseOverlay: UIView {
    var onResume: (() -> Void)?
    var onMode: (() -> Void)?
    var onHost: (() -> Void)?
    var onJoin: (() -> Void)?
    var onTouchSize: ((TouchControlSize) -> Void)?
    var onWorlds: (() -> Void)?

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
        let worlds = makeButton("Save & Choose World", color: UIColor(red: 0.42, green: 0.45, blue: 0.54, alpha: 1))
        worlds.addTarget(self, action: #selector(worldsTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            title, instructions, touchSizeRow, resume, mode, host, join, worlds, status,
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
    @objc private func worldsTapped() { onWorlds?() }
    @objc private func touchSizeChanged() {
        guard let size = TouchControlSize(rawValue: touchSize.selectedSegmentIndex) else { return }
        onTouchSize?(size)
    }
}
