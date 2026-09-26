import Foundation

extension StringProtocol {
    /// At most `limit` Unicode scalars of the text, for a card's budget. A
    /// budget counted in Characters let one cluster carry tens of thousands of
    /// scalars past it, so card budgets count scalars. The cut may split a
    /// cluster; the text stays
    /// valid, and a card is never longer than its budget.
    func scalarPrefix(_ limit: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: unicodeScalars.prefix(limit))
        return String(view)
    }
}
