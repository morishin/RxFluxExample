import UIKit
import RxSwift
import RxCocoa

fileprivate struct State {
    enum NetworkState {
        case nothing
        case requesting
        case error(Error)
    }

    static let initialPage: Int = 1
    var models: [Model]
    var nextPage: NextPage
    var networkState: NetworkState
}

fileprivate enum Action {
    case refreshed(models: [Model], nextPage: NextPage)
    case loadedMore(models: [Model], nextPage: NextPage)
    case requested
    case errorOccured(error: Error)
}

fileprivate class Store {
    static let initialState = State(
        models: [],
        nextPage: .nextPage(State.initialPage),
        networkState: .nothing
    )

    var states: Observable<State> = .empty()
    var currentState: State {
        return try! stateCache.value()
    }

    private let stateCache: BehaviorSubject<State> = BehaviorSubject(value: Store.initialState)

    init(inputs: Observable<View.Event>) {
        states = inputs
            .flatMap { event in ActionCreator.action(for: event, store: self) }
            .scan(Store.initialState, accumulator: Store.reduce)
            .multicast(stateCache)
            .refCount()
    }

    static func reduce(state: State, action: Action) -> State {
        var nextState = state

        switch action {
        case let .refreshed(models, nextPage):
            nextState.models = models
            nextState.nextPage = nextPage
            nextState.networkState = .nothing
        case let .loadedMore(models, nextPage):
            nextState.models += models
            nextState.nextPage = nextPage
            nextState.networkState = .nothing
        case .requested:
            nextState.networkState = .requesting
        case let .errorOccured(error):
            nextState.networkState = .error(error)
        }

        return nextState
    }
}

fileprivate struct ActionCreator {
    static func action(for event: View.Event, store: Store) -> Observable<Action> {
        let currentState = store.currentState

        switch event {
        case .firstViewWillAppear:
            if case .requesting = currentState.networkState {
                return Observable.just(.requested)
            } else {
                let request = ModelRequest(page: State.initialPage)
                let response: Single<ModelRequest.Response> = MockClient.response(to: request)
                return response.asObservable()
                    .map { response -> Action in
                        return .refreshed(models: response.models, nextPage: response.nextPage)
                    }
                    .catchError { error -> Observable<Action> in
                        return .just(.errorOccured(error: error))
                    }
                    .startWith(.requested)
            }
        case .reachedBottom:
            switch currentState.nextPage {
            case .reachedLast:
                return .empty()
            case let .nextPage(nextPage):
                if case .requesting = currentState.networkState {
                    return .just(.requested)
                }
                let request = ModelRequest(page: nextPage)
                let response: Single<ModelRequest.Response> = MockClient.response(to: request)
                return response.asObservable()
                    .map { response -> Action in
                        return .loadedMore(models: response.models, nextPage: response.nextPage)
                    }
                    .catchError { error -> Observable<Action> in
                        return .just(.errorOccured(error: error))
                    }
                    .startWith(.requested)
            }
        }
    }
}

typealias View = ModelTableViewController
class ModelTableViewController: UIViewController, UITableViewDataSource {
    fileprivate enum Event {
        case firstViewWillAppear
        case reachedBottom
    }

    private let store: Store
    private let events = PublishSubject<Event>()
    private let tableView = UITableView()
    private let activityIndicator = UIActivityIndicatorView(activityIndicatorStyle: .gray)
    private let disposeBag = DisposeBag()

    private var models: [Model] = []

    init() {
        store = Store(inputs: events)
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        store.states
            .observeOn(MainScheduler.instance)
            .subscribe(onNext: self.render)
            .disposed(by: disposeBag)

        view.addSubview(tableView)
        tableView.frame = view.bounds
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: String(describing: UITableViewCell.self))

        view.addSubview(activityIndicator)
        activityIndicator.center = view.center

        rx.sentMessage(#selector(viewWillAppear))
            .take(1)
            .subscribe(onNext: { [weak self] _ in
                self?.events.onNext(.firstViewWillAppear)
            })
            .disposed(by: disposeBag)

        tableView.rx.willDisplayCell
            .subscribe(onNext: { [weak self] (cell, indexPath) in
                guard let strongSelf = self else { return }
                if indexPath.row == strongSelf.tableView.numberOfRows(inSection: indexPath.section) - 1 {
                    strongSelf.events.onNext(.reachedBottom)
                }
            })
            .disposed(by: disposeBag)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func render(state: State) {
        switch state.networkState {
        case .nothing:
            activityIndicator.stopAnimating()
        case .requesting:
            activityIndicator.startAnimating()
        case let .error(error):
            let alertController = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "Close", style: .default, handler: nil))
            present(alertController, animated: true, completion: nil)
        }

        models = state.models
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return models.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let model = models[indexPath.row]
        let cell: UITableViewCell = tableView.dequeueReusableCell(withIdentifier: String(describing: UITableViewCell.self), for: indexPath)
        cell.textLabel?.text = model.name
        return cell
    }
}
