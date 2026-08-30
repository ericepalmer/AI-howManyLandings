import SwiftUI

private struct AirportWindowICAOKey: FocusedValueKey {
    typealias Value = String
}

extension FocusedValues {
    var airportWindowICAO: String? {
        get { self[AirportWindowICAOKey.self] }
        set { self[AirportWindowICAOKey.self] = newValue }
    }
}
