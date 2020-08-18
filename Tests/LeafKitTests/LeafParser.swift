import XCTest
import NIOConcurrencyHelpers
@testable import LeafKit

final class LKParserTests: LeafTestClass {
    func testParser() throws {
        let sampleTemplate = """
        #define(aBlock):
            Hello #(name)!
        #enddefine

        #export(anotherBlock):
            Hello #(name)!
        #endexport

        #inline("template1")
        #inline("template2", as: leaf)
        #inline("file1", as: raw)

        #evaluate(aBlock)
        #import(aBlock)
        #extend("template3")

        #(name.hasPrefix("Mr"))

        #if(lowercased(((name == "admin"))) == "welcome"):
            #(0b0101010 + 0o052 + 42 - 0_042 * 0x02A / self.meaning - 0_042.0 + 0x02A.0)
            #if(variable[0] ?? true): subscripting & coalescing #endif
        #elseif(false):
            Abracadabra
            #(one)
        #else:
            Tralala
        #endif

        #(true)
        #for(_ in collection): something #endfor
        #for(value in collection): something #endfor
        #for((key, value) in collection): something #endfor
        #while($request.name.lowercased() == "aValue"): Maybe do something #endwhile
        #repeat(while: self.name != nil): Do something at least once #endrepeat
        """

        let template2 = """
        #evaluate(aBlock ?? "aBlock is not defined")
        """

        var tokens = try lex(sampleTemplate)
        var parser = LKParser(.searchKey("sampleTemplate"), tokens)
        var firstAST = try parser.parse()
        print(firstAST.formatted)

        tokens = try lex(template2)
        parser = LKParser(.searchKey("template2"), tokens)
        let secondAST = try parser.parse()
        print(secondAST.summary)

        let file1 = ByteBufferAllocator().buffer(string: "An inlined raw file")

        firstAST.inline(ast: secondAST)
        firstAST.inline(raws: ["template2" : file1])
        print(firstAST.formatted)

        let sample = """
        #count(self)
        #count(name)
        #(name)
        #(name.lowercased())
        #lowercased(name)
        #(self.name.uppercased())
        #hasPrefix(self.name, "Mr")
        #if(aDict["one"] == 2.0):Ooop!#else:Wrong number#endif
        #(aDict.three[0])
        #(aDict ? "Dictionary Exists" : "No it doesn't")
        #(aDict.count() == 2 ? "Two elements!" : "Wrong count")
        #for(_ in self):.discard. #endfor
        #for(value in self):.value. #endfor
        #for((key, value) in self):.key&value. [#(key) : #(value)]
        #endfor
        """

        let context: [String: LeafData] = [
            "name"  : "Mr. MagOO",
            "aDict" : ["one": 1, "two": 2.0, "three": ["five", "ten"]]
        ]
        let start = Date()
        var sampleParse = try! LKParser(.searchKey("s"), lex(sample))
        let sampleAST = try! sampleParse.parse()
        let parsedTime = start.distance(to: Date())

        print(sampleAST.formatted)
        let serializer = LKSerializer(ast: sampleAST, context: context)
        let buffer = ByteBufferAllocator().buffer(capacity: Int(sampleAST.underestimatedSize))
        var block = ByteBuffer.instantiate(data: buffer, encoding: .utf8)

        let result = serializer.serialize(buffer: &block)
        switch result {
            case .success(let duration):
                print(block.contents)
                print("    Parse: " + parsedTime.formatSeconds)
                print("Serialize: " + duration.formatSeconds)
            case .failure(let error):
                print(error.localizedDescription)
        }
    }

    func testVsComplex() throws {
        let loopCount = 300
        let context: [String: LeafData] = [
            "name"  : "vapor",
            "skills" : Array.init(repeating: ["bool": true.leafData, "string": "a;sldfkj".leafData,"int": 100.leafData], count: loopCount).leafData,
            "me": "LOGAN"
        ]

        let sample = """
        hello, #(name)!
        #for(index in skills):
        #(skills[index])
        #endfor
        """

        var total = 0.0
        var leafBuffer: ByteBuffer = ByteBufferAllocator().buffer(capacity: 0)
        for x in 1...10 {
            var lap = Date()
            var sampleParse = try! LKParser(.searchKey("s"), lex(sample))
            let sampleAST = try! sampleParse.parse()
            print("    Parse: " + lap.distance(to: Date()).formatSeconds)
            lap = Date()
            let serializer = LKSerializer(ast: sampleAST, context: context)
            let buffer = ByteBufferAllocator().buffer(capacity: Int(sampleAST.underestimatedSize))
            var block = ByteBuffer.instantiate(data: buffer, encoding: .utf8)
            print("    Setup: " + lap.distance(to: Date()).formatSeconds)
            let result = serializer.serialize(buffer: &block)
            switch result {
                case .success(let duration) : print("Serialize: " + duration.formatSeconds)
                                              total += duration
                case .failure(let error)    : print(error.localizedDescription)
            }
            if x == 10 { try! leafBuffer.append(&block) }
        }

        let lap = Date()
        var buffered = ByteBufferAllocator().buffer(capacity: 0)
        buffered.append("hello, \(context["name"]!.string!)!\n".leafData)
        for index in context["skills"]!.array!.indices {
            buffered.append(context["skills"]!.array![index])
            buffered.append("\n\n".leafData)
        }
        let rawSwift = lap.distance(to: Date())

        XCTAssert(buffered.writerIndex == leafBuffer.writerIndex, "Raw Swift & Leaf Output Don't Match")

        print("Indices - Leaf: \(leafBuffer.writerIndex) / Raw: \(buffered.writerIndex)")

        print("Raw Swift unwrap and concat: \(rawSwift.formatSeconds)")

        print("Average serialize duration: \((total / 10.0).formatSeconds)")
        print(String(format: "Overhead: %.2f%%", 1000.0 * rawSwift / total))
        print(String("Difference per loop: " + (((total/10.0) - rawSwift)/Double(loopCount)).formatSeconds))
        print("Output size: \(leafBuffer.readableBytes.formatBytes)")
    }

    func testEval() throws {
        let sample = """
        #define(block):
        Is #(self["me"] + " " + name)?: #($context.me == name)
        #enddefine

        #evaluate(block)
        #(# here's a comment #)
        #("And a comment" # On...
                            multiple...
                            lines. # )

        #define(block, nil)
        Defaulted : #evaluate(block ?? "Block doesn't exist")
        No default: #evaluate(block)
        """

        let context: [String: LeafData] = [
            "name": "Teague",
            "me": "Teague"
        ]
        var sampleParse: LKParser
        do {
            sampleParse = try LKParser(.searchKey("s"), lex(sample))
        } catch let e as LeafError { throw e.localizedDescription }
        let sampleAST = try! sampleParse.parse()
        print(sampleAST.formatted)
        let serializer = LKSerializer(ast: sampleAST, context: context)
        let buffer = ByteBufferAllocator().buffer(capacity: Int(sampleAST.underestimatedSize))
        var block = ByteBuffer.instantiate(data: buffer, encoding: .utf8)

        let result = serializer.serialize(buffer: &block)
        switch result {
            case .success        : print(block.contents)
            case .failure(let e) : print(e.localizedDescription)
        }
    }

    func testForAndIf() throws {
        let sample = """
        #for(index in 10):
        #(index): #for((pos, char) in "Hey Teague"):#if(pos != index):#(char)#else:_#endif#endfor#endfor
        """

        let context: [String: LeafData] = [:]
        var sampleParse = try! LKParser(.searchKey("s"), lex(sample))
        let sampleAST = try! sampleParse.parse()
        print(sampleAST.formatted)
        let serializer = LKSerializer(ast: sampleAST, context: context)
        let buffer = ByteBufferAllocator().buffer(capacity: Int(sampleAST.underestimatedSize))
        var block = ByteBuffer.instantiate(data: buffer, encoding: .utf8)

        let result = serializer.serialize(buffer: &block)
        switch result {
            case .success        : print(block.contents)
            case .failure(let e) : print(e.localizedDescription)
        }
    }
  
    func testAssignmentAndCollections() throws {
        let input = """
        #(x = [])
        #(x)
        #(x = [:])
        #(x)
        #(x = [x, 5])
        #(x)
        #(x = ["x": x, "y": 10])
        #(x)
        #(x.x[0])
        """

        let parseExpected = """
         0: [$:x = array(0)]
         2: $:x
         4: [$:x = dictionary(0)]
         6: $:x
         8: [$:x = ($:x, int(5))]
        10: $:x
        12: [$:x = ($:x, int(10))]
        14: $:x
        16: [$:x.x [] int(0)]
        """

        let parsedAST = try! parse(input)
        XCTAssertEqual(parsedAST.terse, parseExpected)
        
        let serializeExpected = """

        []

        [:]

        [[:], 5]

        ["x": [[:], 5], "y": 10]
        [:]
        """
        
        
        let serializer = LKSerializer(ast: parsedAST, context: [:])
        let buffer = ByteBufferAllocator().buffer(capacity: Int(parsedAST.underestimatedSize))
        var block = ByteBuffer.instantiate(data: buffer, encoding: .utf8)
        let result = serializer.serialize(buffer: &block)
        switch result {
            case .success        : XCTAssertEqual(block.contents, serializeExpected)
            case .failure(let e) : print(e.localizedDescription)
        }

    }
}
