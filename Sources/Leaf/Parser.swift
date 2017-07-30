import Bits

enum Operator {
    case add
    case subtract
    case lessThan
    case greaterThan
}

enum Constant {
    case int(Int)
    case double(Double)
    case string([Syntax])
}

indirect enum SyntaxKind {
    case raw(data: Bytes)
    case tag(name: Syntax, parameters: [Syntax], body: [Syntax]?)
    case identifier(name: String)
    case constant(Constant)
    case expression(type: Operator, left: Syntax, right: Syntax)
}

struct Syntax {
    let kind: SyntaxKind
    let source: Source
}

public struct Source {
    let line: Int
    let column: Int
    let range: Range<Int>
}

extension Syntax: CustomStringConvertible {
    var description: String {
        switch kind {
        case .raw(let source):
            return "Raw: `\(source.makeString())`"
        case .tag(let name, let params, let body):
            let params = params.map { $0.description }
            let hasBody = body != nil ? true : false
            return "Tag: \(name)(\(params.joined(separator: ", "))) Body: \(hasBody)"
        case .identifier(let name):
            return "`\(name)`"
        case .expression(let type, let left, let right):
            return "Expr: (\(left) \(type) \(right))"
        case .constant(let const):
            return "c:\(const)"
        }
    }
}

extension Constant: CustomStringConvertible {
    var description: String {
        switch self {
        case .double(let double):
            return double.description
        case .int(let int):
            return int.description
        case .string(let ast):
            return "(" + ast.map { $0 .description }.joined(separator: ", ") + ")"
        }
    }
}

final class Parser {
    let scanner: ByteScanner

    init(_ data: Bytes) {
        self.scanner = ByteScanner(data)
    }

    func parse() throws -> [Syntax] {
        var ast: [Syntax] = []

        var start = scanner.offset
        do {
            while let syntax = try extractSyntax() {
                start = scanner.offset
                ast.append(syntax)
            }
        } catch {
            throw RenderError(
                source: Source(
                    line: scanner.line ,
                    column: scanner.column,
                    range: start..<scanner.offset
                ),
                error: error
            )
        }

        return ast
    }

    private func extractSyntax() throws -> Syntax? {
        guard let byte = scanner.peek() else {
            return nil
        }

        let syntax: Syntax

        switch byte {
        case .numberSign:
            syntax = try extractTag()
        default:
            let start = scanner.offset
            let line = scanner.line
            let column = scanner.column

            let bytes = try extractRaw()

            let source = Source(line: line, column: column, range: start..<scanner.offset)
            return Syntax(kind: .raw(data: bytes), source: source)
        }

        return syntax
    }

    private func extractTag() throws -> Syntax {
        let start = scanner.offset
        let line = scanner.line
        let column = scanner.column

        try expect(.numberSign)
        let id = try extractIdentifier()
        let params = try extractParameters()
        try skipWhitespace()

        let body: [Syntax]?

        if let byte = scanner.peek() {
            if byte == .leftCurlyBracket {
                body = try extractBody()
            } else {
                body = nil
            }
        } else {
            body = nil
        }

        let kind: SyntaxKind = .tag(
            name: id,
            parameters: params,
            body: body
        )
        
        let source = Source(line: line, column: column, range: start..<scanner.offset)
        return Syntax(kind: kind, source: source)
    }

    private func extractBody() throws -> [Syntax] {
        try expect(.leftCurlyBracket)
        let body = try bytes(until: .rightCurlyBracket)
        try expect(.rightCurlyBracket)
        let parser = Parser(body)
        return try parser.parse()
    }

    private func extractRaw() throws -> Bytes {
        return try bytes(until: .numberSign)
    }

    private func bytes(until: Byte) throws -> Bytes {
        var previous: Byte?

        var bytes: Bytes = []
        while let byte = scanner.peek(), byte != until || previous == .backSlash {
            try scanner.pop()
            if byte != until && previous == .backSlash {
                bytes.append(.backSlash)
            }
            if byte != .backSlash {
                bytes.append(byte)
            }
            previous = byte
        }

        return bytes
    }

    private func extractIdentifier() throws -> Syntax {
        let start = scanner.offset
        let line = scanner.line
        let column = scanner.column

        while let byte = scanner.peek(), byte.isAlphanumeric {
           try scanner.pop()
        }
        
        let bytes = scanner.bytes[start..<scanner.offset]

        let kind: SyntaxKind = .identifier(name: bytes.makeString())
        let source = Source(line: line, column: column, range: start..<scanner.offset)

        return Syntax(kind: kind, source: source)
    }

    private func extractParameters() throws -> [Syntax] {
        try expect(.leftParenthesis)

        var params: [Syntax] = []
        repeat {
            if params.count > 0 {
                try expect(.comma)
            }

            if let param = try extractParameter() {
                params.append(param)
            }
        } while scanner.peek() == .comma

        try expect(.rightParenthesis)

        return params
    }

    private func extractNumber() throws -> Constant {
        let start = scanner.offset
        while let byte = scanner.peek(), byte.isDigit || byte == .period {
            try scanner.pop()
        }

        let bytes = scanner.bytes[start..<scanner.offset]
        let string = bytes.makeString()
        if bytes.contains(.period) {
            guard let double = Double(string) else {
                throw "Unexpected non double"
            }
            return .double(double)
        } else {
            guard let int = Int(string) else {
                throw "Unexpected non int"
            }
            return .int(int)
        }

    }

    private func extractParameter() throws -> Syntax? {
        try skipWhitespace()

        let start = scanner.offset
        let line = scanner.line
        let column = scanner.column

        guard let byte = scanner.peek() else {
            throw "Unexpected EOF"
        }

        let kind: SyntaxKind

        switch byte {
        case .rightParenthesis:
            return nil
        case .quote:
            try expect(.quote)
            let bytes = try self.bytes(until: .quote)
            try expect(.quote)
            let parser = Parser(bytes)
            let ast = try parser.parse()
            kind = .constant(
                .string(ast)
            )
        default:
            if byte.isDigit {
                // constant number
                let num = try extractNumber()
                kind = .constant(num)
            } else {
                let id = try extractIdentifier()

                try skipWhitespace()

                let op: Operator?

                if let byte = scanner.peek() {
                    switch byte {
                    case .lessThan:
                        op = .lessThan
                    case .greaterThan:
                        op = .greaterThan
                    case .hyphen:
                        op = .subtract
                    case .plus:
                        op = .add
                    default:
                        op = nil
                    }
                } else {
                    op = nil
                }

                if let op = op {
                    try scanner.pop()

                    guard let right = try extractParameter() else {
                        throw "Expected right parameter"
                    }

                    kind = .expression(
                        type: op,
                        left: id,
                        right: right
                    )
                } else {
                    kind = id.kind
                }
            }
        }

        let source = Source(line: line, column: column, range: start..<scanner.offset)
        return Syntax(kind: kind, source: source)
    }

    private func skipWhitespace() throws {
        while let byte = scanner.peek(), byte == .space {
            try scanner.pop()
        }
    }

    private func expect(_ expect: Byte) throws {
        guard let byte = scanner.peek() else {
            throw "Unexpected EOF"
        }

        guard byte == expect else {
            throw "Expected `\(expect.makeString())`, got `\(byte.makeString())`"
        }

        try scanner.pop()
    }
}

extension Byte {
    static let lessThan: Byte = 0x3C
    static let greaterThan: Byte = 0x3E
}

extension Byte {
    func makeString() -> String {
        return [self].makeString()
    }
}

extension String: Error { }