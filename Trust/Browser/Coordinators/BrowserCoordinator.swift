// Copyright SIX DAY LLC. All rights reserved.

import Foundation
import UIKit
import BigInt
import TrustKeystore
import RealmSwift
import URLNavigator

protocol BrowserCoordinatorDelegate: class {
    func didSentTransaction(transaction: SentTransaction, in coordinator: BrowserCoordinator)
}

class BrowserCoordinator: Coordinator {
    var coordinators: [Coordinator] = []
    let session: WalletSession
    let keystore: Keystore
    let navigationController: UINavigationController

    lazy var rootViewController: BrowserViewController = {
        let controller = BrowserViewController(account: session.account, config: session.config)
        controller.delegate = self
        return controller
    }()
    private let sharedRealm: Realm
    private lazy var bookmarksStore: BookmarksStore = {
        return BookmarksStore(realm: sharedRealm)
    }()
    private lazy var historyStore: HistoryStore = {
        return HistoryStore(realm: sharedRealm)
    }()

    weak var delegate: BrowserCoordinatorDelegate?

    init(
        session: WalletSession,
        keystore: Keystore,
        navigator: Navigator,
        sharedRealm: Realm
    ) {
        self.navigationController = UINavigationController(navigationBarClass: BrowserNavigationBar.self, toolbarClass: nil)
        self.session = session
        self.keystore = keystore
        self.sharedRealm = sharedRealm
    }

    func start() {
        navigationController.viewControllers = [rootViewController]
        rootViewController.goHome()
    }

    @objc func dismiss() {
        navigationController.dismiss(animated: true, completion: nil)
    }

    private func executeTransaction(account: Account, action: DappAction, callbackID: Int, transaction: UnconfirmedTransaction, type: ConfirmType) {
        let configurator = TransactionConfigurator(
            session: session,
            account: account,
            transaction: transaction
        )
        let coordinator = ConfirmCoordinator(
            navigationController: UINavigationController(),
            session: session,
            configurator: configurator,
            keystore: keystore,
            account: account,
            type: type
        )
        addCoordinator(coordinator)
        coordinator.didCompleted = { [unowned self] result in
            switch result {
            case .success(let type):
                switch type {
                case .signedTransaction(let transaction):
                    // on signing we pass signed hex of the transaction
                    let callback = DappCallback(id: callbackID, value: .signTransaction(transaction.data))
                    self.rootViewController.notifyFinish(callbackID: callbackID, value: .success(callback))
                    self.delegate?.didSentTransaction(transaction: transaction, in: self)
                case .sentTransaction(let transaction):
                    // on send transaction we pass transaction ID only.
                    let data = Data(hex: transaction.id)
                    let callback = DappCallback(id: callbackID, value: .sentTransaction(data))
                    self.rootViewController.notifyFinish(callbackID: callbackID, value: .success(callback))
                    self.delegate?.didSentTransaction(transaction: transaction, in: self)
                }
            case .failure:
                self.rootViewController.notifyFinish(
                    callbackID: callbackID,
                    value: .failure(DAppError.cancelled)
                )
            }
            self.removeCoordinator(coordinator)
            self.navigationController.dismiss(animated: true, completion: nil)
        }
        coordinator.start()
        navigationController.present(coordinator.navigationController, animated: true, completion: nil)
    }

    func showBookmarks(for view: BookmarksViewType) {
        let coordinator = BookmarkCoordinator(
            navigationController: NavigationController(),
            bookmarksStore: bookmarksStore,
            historyStore: historyStore,
            type: view
        )
        coordinator.delegate = self
        coordinator.start()
        addCoordinator(coordinator)
        navigationController.present(coordinator.navigationController, animated: true, completion: nil)
    }

    func openURL(_ url: URL) {
        rootViewController.goTo(url: url)
    }

    func signMessage(with type: SignMesageType, account: Account, callbackID: Int) {
        let coordinator = SignMessageCoordinator(
            navigationController: navigationController,
            keystore: keystore,
            account: account
        )
        coordinator.didComplete = { [weak self] result in
            guard let `self` = self else { return }
            switch result {
            case .success(let data):
                let callback: DappCallback
                switch type {
                case .message:
                    callback = DappCallback(id: callbackID, value: .signMessage(data))
                case .personalMessage:
                    callback = DappCallback(id: callbackID, value: .signPersonalMessage(data))
                case .typedMessage:
                    callback = DappCallback(id: callbackID, value: .signTypedMessage(data))
                }
                self.rootViewController.notifyFinish(callbackID: callbackID, value: .success(callback))
            case .failure:
                self.rootViewController.notifyFinish(callbackID: callbackID, value: .failure(DAppError.cancelled))
            }
            self.removeCoordinator(coordinator)
        }
        coordinator.delegate = self
        addCoordinator(coordinator)
        coordinator.start(with: type)
    }

    func presentQRCodeReader() {
        let coordinator = ScanQRCodeCoordinator(
            navigationController: NavigationController()
        )
        coordinator.delegate = self
        addCoordinator(coordinator)
        navigationController.present(coordinator.qrcodeController, animated: true, completion: nil)
    }
}

extension BrowserCoordinator: BookmarksCoordinatorDelegate {
    func didCancel(in coordinator: BookmarkCoordinator) {
        coordinator.navigationController.dismiss(animated: true, completion: nil)
        removeCoordinator(coordinator)
    }

    func didSelectURL(_ url: URL, in coordinator: BookmarkCoordinator) {
        coordinator.navigationController.dismiss(animated: true, completion: nil)
        removeCoordinator(coordinator)
        openURL(url)
    }
}

extension BrowserCoordinator: BrowserViewControllerDelegate {

    func runAction(action: BrowserAction) {
        switch action {
        case .bookmarks:
            showBookmarks(for: .bookmarks)
        case .addBookmark(let bookmark):
            bookmarksStore.add(bookmarks: [bookmark])
        case .qrCode:
            presentQRCodeReader()
        case .history:
            showBookmarks(for: .history)
        }
    }

    func didCall(action: DappAction, callbackID: Int) {
        switch session.account.type {
        case .privateKey(let account), .hd(let account) :
            switch action {
            case .signTransaction(let unconfirmedTransaction):
                executeTransaction(account: account, action: action, callbackID: callbackID, transaction: unconfirmedTransaction, type: .sign)
            case .sendTransaction(let unconfirmedTransaction):
                executeTransaction(account: account, action: action, callbackID: callbackID, transaction: unconfirmedTransaction, type: .signThenSend)
            case .signMessage(let hexMessage):
                signMessage(with: .message(Data(hex: hexMessage)), account: account, callbackID: callbackID)
            case .signPersonalMessage(let hexMessage):
                signMessage(with: .personalMessage(Data(hex: hexMessage)), account: account, callbackID: callbackID)
            case .signTypedMessage(let typedData):
                signMessage(with: .typedMessage(typedData), account: account, callbackID: callbackID)
            case .unknown:
                break
            }
        case .address:
            self.rootViewController.notifyFinish(callbackID: callbackID, value: .failure(DAppError.cancelled))
            self.navigationController.displayError(error: InCoordinatorError.onlyWatchAccount)
        }
    }

    func didVisitURL(url: URL, title: String) {
        historyStore.record(url: url, title: title)
    }
}

extension BrowserCoordinator: SignMessageCoordinatorDelegate {
    func didCancel(in coordinator: SignMessageCoordinator) {
        removeCoordinator(coordinator)
    }
}

extension BrowserCoordinator: ConfirmCoordinatorDelegate {
    func didCancel(in coordinator: ConfirmCoordinator) {
        navigationController.dismiss(animated: true, completion: nil)
        removeCoordinator(coordinator)
    }
}

extension BrowserCoordinator: ScanQRCodeCoordinatorDelegate {
    func didCancel(in coordinator: ScanQRCodeCoordinator) {
        coordinator.navigationController.dismiss(animated: true, completion: nil)
        removeCoordinator(coordinator)
    }

    func didScan(result: String, in coordinator: ScanQRCodeCoordinator) {
        coordinator.navigationController.dismiss(animated: true, completion: nil)
        removeCoordinator(coordinator)
        guard let url = URL(string: result) else {
            return
        }
        openURL(url)
    }
}
