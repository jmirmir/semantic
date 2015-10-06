/// A two-dimensional matrix of memoized values.
///
/// These values are populated by a function from the coordinates of a given cell to the matrix’s element type.
///
/// Values are retrieved by subscripting with row/column indices. Out-of-bound indices produce `nil` values, rather than asserting.
public struct Matrix<A> {
	public init(width: Int, height: Int, compute: (Int, Int) -> A) {
		var values: [Memo<A>] = []
		values.reserveCapacity(width * height)

		for i in 0..<width {
			for j in 0..<height {
				values.append(Memo<A> { compute(i, j) })
			}
		}

		self.init(width: width, height: height, values: values)
	}

	public let width: Int
	public let height: Int

	private let values: [Memo<A>]

	public subscript (i: Int, j: Int) -> Memo<A>? {
		guard i < width && j < height else { return nil }
		return values[i + j * height]
	}


	// MARK: Functor

	public func map<Other>(transform: A -> Other) -> Matrix<Other> {
		return Matrix<Other>(width: width, height: height, values: values.map { $0.map(transform) })
	}


	// MARK: Implementation details

	private init(width: Int, height: Int, values: [Memo<A>]) {
		self.width = width
		self.height = height
		self.values = values
	}
}
