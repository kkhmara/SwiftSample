import Combine
import UIKit

protocol HoldOrderListVCDelegate: AnyObject {
    func holdOrderListController(_ controller: HoldOrderListVC, didHoldOrders holdOrders: [HoldOrder])
    func holdOrderListController(_ controller: HoldOrderListVC, unholdOrderWithoutCurrentCart holdOrders: [HoldOrder])
    func holdOrderListController(_ controller: HoldOrderListVC, unholdOrderAndHoldCurrentCart cart: Cart?)
    func holdOrderListController(_ controller: HoldOrderListVC, pushHoldOrderCustomerListVC holdOrderID: Int?)
}

final class HoldOrderListVC: UIViewController {
    // MARK: - Constatns
    private enum Constants {
        static let standardOffset: CGFloat = 16
        static let miniOffset: CGFloat = 8
        static let actionLabelText = "There are now 0 orders on hold".localized
        static let searchPlaceholderText = "Search orders on hold by name".localized
        static let alertTitle = "View Order on Hold".localized
        static let alertDesc = "You have unsaved cart. Delete current cart or put it on hold?".localized
        static let deleteTitle = "Delete Order".localized
        static let title = "Hold Order".localized
    }
    
    // MARK: - Properties
    weak var delegate: HoldOrderListVCDelegate?
    private let activityIndicator = ActivityIndicatorVC()
    private let viewModel: HoldOrderVM
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - UI
    private var actionLabel = UILabel().then {
        $0.text = Constants.actionLabelText
        $0.textColor = .secondaryLabel
    }
    
    private var createHoldOrderButton = UIButton().then {
        UIButtonStyle.createHoldOrderButton.apply(to: $0)
        $0.setTitle(" Hold Order", for: .normal)
    }
    
    private var searchBar = UISearchBar().then {
        SearchBarStyle.table.apply(to: $0)
        $0.placeholder = Constants.searchPlaceholderText
    }
        
    private lazy var tableView = UITableView(frame: .zero, style: .insetGrouped).then {
        $0.rowHeight = 60
    }
    
    // MARK: - Life cycle
    init(viewModel: HoldOrderVM) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupNavigationBar()
        setupUI()
        bindUI()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.searchText = ""
    }
    
    // MARK: - Private Methods
    private func setupUI() {
        view.backgroundColor = .systemGray6
                
        view.addSubview(actionLabel)
        actionLabel.snp.makeConstraints {
            $0.center.equalToSuperview()
        }
        
        let hasCart = ShopManager.shared.currentCart != nil
        view.addSubview(createHoldOrderButton)
        createHoldOrderButton.isHidden = !hasCart
        createHoldOrderButton.snp.makeConstraints {
            $0.top.left.right.equalToSuperview().inset(Constants.standardOffset)
            $0.height.equalTo(hasCart ? 56 : 0)
        }
        
        view.addSubview(searchBar)
        searchBar.snp.makeConstraints {
            $0.left.right.equalToSuperview().inset(Constants.miniOffset)
            if hasCart {
                $0.top.equalTo(createHoldOrderButton.snp.bottom).offset(Constants.miniOffset)
            } else {
                $0.top.equalToSuperview().offset(Constants.standardOffset)
            }
        }
        
        view.addSubview(tableView)
        tableView.snp.makeConstraints {
            $0.left.right.equalToSuperview()
            $0.top.equalTo(searchBar.snp.bottom)
            $0.bottom.equalToSuperview().inset(Constants.standardOffset)
        }
    }
    
    private func bindUI() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(HoldOrderCell.self, forCellReuseIdentifier: HoldOrderCell.idealReuseIdentifier)
        createHoldOrderButton.addAction(holdOrderButtonTapped(), for: .touchDown)
        
        viewModel.orderWasDeleted
            .filter { $0 }
            .sink { [weak self] _ in
                self?.dismiss(animated: false, completion: {
                    ShopManager.shared.needsUIUpdate.send()
                    ShopCoordinator.shared.startSecondaryFlow(animated: false)
                })
            }
            .store(in: &cancellables)
        
        viewModel.$filteredHoldOrders
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateUI()
            }
            .store(in: &cancellables)
        
        searchBar.textDidChangePublisher
            .removeDuplicates()
            .debounce(for: 0.6, scheduler: DispatchQueue.main)
            .weakAssign(to: \.searchText, on: viewModel)
            .store(in: &cancellables)
        
        viewModel.loadingActivity.loading
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.isAnimating, on: activityIndicator)
            .store(in: &cancellables)

        updateUI()
    }
    
    private func updateUI() {
        tableView.isHidden = viewModel.holdOrders.isEmpty
        searchBar.isHidden = viewModel.holdOrders.isEmpty
        actionLabel.isHidden = !viewModel.holdOrders.isEmpty
        tableView.reloadData()
    }
    
    private func setupNavigationBar() {
        title = Constants.title
        NavigationBarStyle.standardBar.apply(to: navigationController?.navigationBar)
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self,
                                                           action: #selector(cancelButtonTapped))
    }
    
    @objc private func cancelButtonTapped() {
        dismiss(animated: true)
    }
    
    private func holdOrderButtonTapped() -> UIAction {
        UIAction { [weak self] _ in
            guard let cart = ShopManager.shared.currentCart, let self = self else {
                return
            }
            if cart.customerID == nil || cart.customerID == 0
                || cart.cartTickets.contains(where: { $0.type == .toGo }) {
                self.delegate?.holdOrderListController(self, pushHoldOrderCustomerListVC: nil)
            } else {
                let customerName = ShopManager.shared.currentHoldOrder?.customerName
                let customerPhone = ShopManager.shared.currentHoldOrder?.customerPhone
                self.createHoldOrder(cart: cart, customerName: customerName, customerPhone: customerPhone)
            }
        }
    }
    
    private func createHoldOrder(cart: Cart, customerName: String? = nil, customerPhone: String? = nil) {
        viewModel.createHoldOrder(cart: cart, customerName: customerName, customerPhone: customerPhone)
            .catch { error -> Empty in
                ShopCoordinator.shared.presentErrorAlert(error: error)
                return Empty()
            }
            .sink { [unowned self] holdOrders in
                delegate?.holdOrderListController(self, didHoldOrders: holdOrders)
            }
            .store(in: &cancellables)
    }
    
    private func unholdAndHoldOrder(currentCart: Cart, holdOrderID: Int, customerName: String? = nil,
                                    customerPhone: String? = nil) {
        viewModel.holdAndUnhold(сurrentCart: currentCart, holdOrderCartID: holdOrderID, customerName: customerName,
                                customerPhone: customerPhone)
            .catch { error -> Empty in
                ShopCoordinator.shared.presentErrorAlert(error: error)
                return Empty()
            }
            .sink { [unowned self] holdOrders in
                viewModel.holdOrders = holdOrders
                delegate?.holdOrderListController(self, unholdOrderAndHoldCurrentCart: nil)
            }
            .store(in: &cancellables)
    }
    
    private func unholdOrder(cartID: Int) {
        viewModel.unholdOrder(cartID: cartID)
            .catch { error -> Empty in
                ShopCoordinator.shared.presentErrorAlert(error: error)
                return Empty()
            }
            .sink { [unowned self] result in
                delegate?.holdOrderListController(self, unholdOrderWithoutCurrentCart: result)
            }
            .store(in: &cancellables)
    }
    
    private func createAlertForCartCheck(holdOrderID: Int, holdOrder: HoldOrder) -> [UIAlertAction] {
        let onHoldAction = UIAlertAction(title: "On Hold", style: .default) { [weak self] _ in
            guard let cart = ShopManager.shared.currentCart, let self = self else {
                return
            }
            if cart.customerID == nil || cart.customerID == 0
                || cart.cartTickets.contains(where: { $0.type == .toGo }) {
                self.delegate?.holdOrderListController(self, pushHoldOrderCustomerListVC: holdOrderID)
                ShopManager.shared.currentHoldOrder = holdOrder
            } else {
                let customerName = ShopManager.shared.currentHoldOrder?.customerName
                let customerPhone = ShopManager.shared.currentHoldOrder?.customerPhone
                self.unholdAndHoldOrder(currentCart: cart, holdOrderID: holdOrderID, customerName: customerName,
                                        customerPhone: customerPhone)
                ShopManager.shared.currentHoldOrder = holdOrder
            }
        }
        
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            ShopManager.shared.currentCart = nil
            ShopManager.shared.currentHoldOrder = holdOrder
            self?.unholdOrder(cartID: holdOrderID)
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .default)
        return [onHoldAction, deleteAction, cancelAction]
    }
    
    private func checkCartIsEmpty(holdOrderID: Int, holdOrder: HoldOrder) {
        if ShopManager.shared.currentCart != nil {
            ShopCoordinator.shared.presentAlert(title: Constants.alertTitle, message: Constants.alertDesc,
                                                actions: createAlertForCartCheck(holdOrderID: holdOrderID,
                                                                                 holdOrder: holdOrder))
        } else {
            ShopManager.shared.currentHoldOrder = holdOrder
            unholdOrder(cartID: holdOrderID)
        }
    }
    
    private func deleteHoldOrder(cartID: Int) {
        viewModel.deleteHoldOrder(cartID: cartID)
            .catch { error -> Empty in
                ShopCoordinator.shared.presentErrorAlert(error: error)
                return Empty()
            }
            .sink { [weak self] holdOrders in
                self?.viewModel.holdOrders = holdOrders
            }
            .store(in: &cancellables)
    }
}

// MARK: - UITableViewDelegate
extension HoldOrderListVC: UITableViewDelegate {
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: nil) { [unowned self] _, _, success in
            success(true)
            deleteHoldOrder(cartID: viewModel.filteredHoldOrders[indexPath.row].cartID)
        }
        deleteAction.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        checkCartIsEmpty(holdOrderID: viewModel.filteredHoldOrders[indexPath.row].cartID,
                         holdOrder: viewModel.filteredHoldOrders[indexPath.row])
    }
}

// MARK: - UITableViewDataSource
extension HoldOrderListVC: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.filteredHoldOrders.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withClass: HoldOrderCell.self, for: indexPath)
        cell.setup(with: viewModel.filteredHoldOrders[indexPath.row])
        return cell
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "\(viewModel.filteredHoldOrders.count) Orders on Hold"
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        32
    }
}
