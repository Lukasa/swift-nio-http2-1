//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import XCTest
import NIO
import NIOHTTP1
import CNIONghttp2
@testable import NIOHTTP2
import NIOHPACK



/// This frame catches data frames and records them.
///
/// It passes the underlying objects to the channel to be fulfilled by the regular embedded channel future fulfilling
/// promise.
class DataFrameCatcher: ChannelOutboundHandler {
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = IOData

    var writtenFrames: [HTTP2Frame] = []

    func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = self.unwrapOutboundIn(data)
        self.writtenFrames.append(frame)

        switch frame.payload {
        case .data(let data):
            ctx.write(self.wrapOutboundOut(data), promise: promise)
        default:
            promise?.succeed(result: ())
        }
    }
}


class FlowControlHandlerTests: XCTestCase {
    var channel: EmbeddedChannel!
    private var frameCatcher: DataFrameCatcher!

    override func setUp() {
        self.channel = EmbeddedChannel()
        self.frameCatcher = DataFrameCatcher()
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: self.frameCatcher).wait())
        XCTAssertNoThrow(try self.channel.pipeline.add(handler: NIOHTTP2FlowControlHandler()).wait())
    }

    override func tearDown() {
        self.channel = nil
        self.frameCatcher = nil
    }

    private func makeWritePromise() -> EventLoopPromise<Void> {
        return self.channel.eventLoop.newPromise()
    }

    private func receivedFrames() -> [HTTP2Frame] {
        defer {
            self.frameCatcher.writtenFrames = []
        }
        return self.frameCatcher.writtenFrames
    }

    func testJustLettingDataThrough() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        let firstWritePromise = self.makeWritePromise()
        var firstWriteComplete = false
        firstWritePromise.futureResult.whenComplete {
            firstWriteComplete = true
        }

        let writtenBuffer = self.channel.writeDataFrame(streamOne, byteBufferSize: 15, promise: firstWritePromise)
        XCTAssertFalse(firstWriteComplete)
        XCTAssertEqual(0, self.receivedFrames().count)

        self.channel.flush()
        XCTAssertTrue(firstWriteComplete)
        let receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: writtenBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testSimpleFramesKeepBoundaries() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        let firstWrittenBuffer = self.channel.writeDataFrame(streamOne, byteBufferSize: 5)
        let secondWrittenBuffer = self.channel.writeDataFrame(streamOne, byteBufferSize: 5)
        let thirdWrittenBuffer = self.channel.writeDataFrame(streamOne, byteBufferSize: 5)
        XCTAssertEqual(0, self.receivedFrames().count)

        self.channel.flush()
        let receivedFrames = self.receivedFrames()
        XCTAssertEqual(3, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: firstWrittenBuffer)
        receivedFrames[1].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: secondWrittenBuffer)
        receivedFrames[2].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: thirdWrittenBuffer)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testOverlargeFramesAreSplitByteBuffer() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        var firstWrittenBuffer = self.channel.writeDataFrame(streamOne, byteBufferSize: 50)
        XCTAssertEqual(0, self.receivedFrames().count)

        self.channel.flush()
        var receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: firstWrittenBuffer.readSlice(length: 15)!)

        // Update the window. Nothing is written immediately.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 20)
        XCTAssertEqual(0, self.receivedFrames().count)

        // Fire read complete.
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: firstWrittenBuffer.readSlice(length: 20)!)

        // And again, we get the rest.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 20)
        XCTAssertEqual(0, self.receivedFrames().count)

        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: firstWrittenBuffer.readSlice(length: 15)!)

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testOverlargeFramesAreSplitFileRegion() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        let firstWrittenRegion = self.channel.writeDataFrame(streamOne, fileRegionSize: 50)
        XCTAssertEqual(0, self.receivedFrames().count)

        self.channel.flush()
        var receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: FileRegion(fileHandle: firstWrittenRegion.fileHandle, readerIndex: 0, endIndex: 15))

        // Update the window. Nothing is written immediately.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 20)
        XCTAssertEqual(0, self.receivedFrames().count)

        // Fire read complete.
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: FileRegion(fileHandle: firstWrittenRegion.fileHandle, readerIndex: 15, endIndex: 35))

        // And again, we get the rest.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 20)
        XCTAssertEqual(0, self.receivedFrames().count)

        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: FileRegion(fileHandle: firstWrittenRegion.fileHandle, readerIndex: 35, endIndex: 50))

        XCTAssertNoThrow(try self.channel.finish())
    }

    func testIgnoresNonDataFramesForStream() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        // Let's start by consuming the window.
        self.channel.writeDataFrame(streamOne, byteBufferSize: 15)
        self.channel.flush()
        XCTAssertEqual(1, self.receivedFrames().count)

        // Now we send another data frame to buffer.
        let bufferedFrame = self.channel.writeDataFrame(streamOne, byteBufferSize: 15)

        // We also send a WindowUpdate frame, a RST_STREAM frame, and a PRIORITY frame.
        let windowUpdateFrame = HTTP2Frame(streamID: streamOne, payload: .windowUpdate(windowSizeIncrement: 500))
        let priorityFrame = HTTP2Frame(streamID: streamOne, payload: .priority(.init(exclusive: false, dependency: .init(knownID: 0), weight: 50)))
        let rstStreamFrame = HTTP2Frame(streamID: streamOne, payload: .rstStream(.protocolError))

        // All of these frames are written.
        var frameWriteCount = 0
        self.channel.write(windowUpdateFrame).whenComplete {
            XCTAssertEqual(frameWriteCount, 0)
            frameWriteCount = 1
        }
        self.channel.write(priorityFrame).whenComplete {
            XCTAssertEqual(frameWriteCount, 1)
            frameWriteCount = 2
        }
        self.channel.write(rstStreamFrame).whenComplete {
            XCTAssertEqual(frameWriteCount, 2)
            frameWriteCount = 3
        }
        XCTAssertEqual(frameWriteCount, 3)

        // But the DATA frame is not.
        var receivedFrames = self.receivedFrames()
        XCTAssertEqual(3, receivedFrames.count)
        receivedFrames[0].assertWindowUpdateFrame(streamID: streamOne.networkStreamID!, windowIncrement: 500)
        receivedFrames[1].assertPriorityFrame()
        receivedFrames[2].assertRstStreamFrame(streamID: streamOne.networkStreamID!, errorCode: .protocolError)

        // Even when we flush.
        self.channel.flush()
        XCTAssertEqual(0, self.receivedFrames().count)

        // Unless we open the window.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 20)
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(1, receivedFrames.count)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: bufferedFrame)
    }

    func testProperlyDelaysENDSTREAMFlag() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        // We send a large DATA frame here.
        var frameWritten = false
        let framePromise: EventLoopPromise<Void> = self.channel.eventLoop.newPromise()
        framePromise.futureResult.map {
            frameWritten = true
        }.whenFailure {
            XCTFail("Unexpected write failure: \($0)")
        }

        var payload = self.channel.writeDataFrame(streamOne, byteBufferSize: 50, flags: .endStream)
        XCTAssertFalse(frameWritten)

        // Flush out the first frame.
        self.channel.flush()
        var receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: payload.readSlice(length: 15)!)

        // Open the window, we get the second frame.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 34)
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: payload.readSlice(length: 34)!)

        // If we open again, we get the final frame, with endStream set.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 200)
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertDataFrame(endStream: true, streamID: streamOne.networkStreamID!, payload: payload.readSlice(length: 1)!)
    }

    func testInterlacingWithHeaders() {
        // The purpose of this test is to validate that headers frames after the first DATA frame are appropriately queued.
        let streamOne = HTTP2StreamID(knownID: 1)

        // Start by sending a headers frame through, even before createStream is fired. This should pass unmolested.
        let headers = HTTP2Frame(streamID: streamOne, flags: .endHeaders, payload: .headers(HPACKHeaders([("name", "value")]), nil))
        self.channel.write(headers, promise: nil)
        var receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertHeadersFrameMatches(this: headers)

        // Now send createStream, and another headers frame. This is also fine.
        self.channel.createStream(streamOne, initialWindowSize: 15)
        self.channel.write(headers, promise: nil)
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertHeadersFrameMatches(this: headers)

        // Now send a large DATA frame that is going to be buffered, followed by a HEADERS frame.
        let endHeaders = HTTP2Frame(streamID: streamOne, flags: [.endHeaders, .endStream], payload: .headers(HPACKHeaders([("name", "value")]), nil))
        var writtenData = self.channel.writeDataFrame(streamOne, byteBufferSize: 50)
        self.channel.write(endHeaders, promise: nil)
        self.channel.flush()

        // So far we've written only a data frame.
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: writtenData.readSlice(length: 15)!)

        // Open the window enough to let another data frame through.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 34)
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: writtenData.readSlice(length: 34)!)

        // Now open it again. This pushes the data frame through, AND the trailers follow.
        self.channel.updateStreamWindowSize(streamOne, newWindowSize: 1)
        self.channel.pipeline.fireChannelReadComplete()
        receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 2)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: writtenData.readSlice(length: 1)!)
        receivedFrames[1].assertHeadersFrameMatches(this: endHeaders)
    }

    func testBufferedDataAndHeadersAreCancelledOnStreamClosure() {
        let streamOne = HTTP2StreamID(knownID: 1)
        self.channel.createStream(streamOne, initialWindowSize: 15)

        // Send a DATA frame that's too big, and a HEADERS frame. We will expect
        // these to both fail.
        let dataPromise: EventLoopPromise<Void> = self.channel.eventLoop.newPromise()
        let headersPromise: EventLoopPromise<Void> = self.channel.eventLoop.newPromise()

        var writtenData = self.channel.writeDataFrame(streamOne, byteBufferSize: 50, promise: dataPromise)
        self.channel.write(HTTP2Frame(streamID: streamOne, payload: .headers(HPACKHeaders([("key", "value")]), nil)), promise: headersPromise)
        self.channel.flush()

        var receivedFrames = self.receivedFrames()
        XCTAssertEqual(receivedFrames.count, 1)
        receivedFrames[0].assertDataFrame(endStream: false, streamID: streamOne.networkStreamID!, payload: writtenData.readSlice(length: 15)!)

        // Ok, drop the stream.
        self.channel.closeStream(streamOne, reason: .protocolError)

        XCTAssertThrowsError(try dataPromise.futureResult.wait()) {
            guard let err = $0 as? NIOHTTP2Errors.StreamClosed else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
            XCTAssertEqual(err.errorCode, .protocolError)
        }
        XCTAssertThrowsError(try headersPromise.futureResult.wait()) {
            guard let err = $0 as? NIOHTTP2Errors.StreamClosed else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
            XCTAssertEqual(err.errorCode, .protocolError)
        }
    }

    func testWritesForUnknownStreamsFail() {
        let streamOne = HTTP2StreamID(knownID: 1)
        let dataPromise: EventLoopPromise<Void> = self.channel.eventLoop.newPromise()

        self.channel.writeDataFrame(streamOne, byteBufferSize: 50, promise: dataPromise)

        XCTAssertThrowsError(try dataPromise.futureResult.wait()) {
            guard let err = $0 as? NIOHTTP2Errors.NoSuchStream else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
        }
        XCTAssertThrowsError(try self.channel.throwIfErrorCaught()) {
            guard let err = $0 as? NIOHTTP2Errors.NoSuchStream else {
                XCTFail("Got unexpected error: \($0)")
                return
            }
            XCTAssertEqual(err.streamID, streamOne)
        }
    }
}


/// Various helpers for EmbeddedChannel that make tests easier to understand.
private extension EmbeddedChannel {
    func createStream(_ streamID: HTTP2StreamID, initialWindowSize: Int32) {
        self.pipeline.fireUserInboundEventTriggered(NIOHTTP2StreamCreatedEvent(streamID: streamID, initialWindowSize: initialWindowSize))
    }

    func updateStreamWindowSize(_ streamID: HTTP2StreamID, newWindowSize: Int32) {
        self.pipeline.fireUserInboundEventTriggered(NIOHTTP2WindowUpdatedEvent(streamID: streamID, newWindowSize: newWindowSize))
    }

    func closeStream(_ streamID: HTTP2StreamID, reason: HTTP2ErrorCode?) {
        self.pipeline.fireUserInboundEventTriggered(StreamClosedEvent(streamID: streamID, reason: reason))
    }

    @discardableResult
    func writeDataFrame(_ streamID: HTTP2StreamID, byteBufferSize: Int, flags: HTTP2Frame.FrameFlags = .init(), promise: EventLoopPromise<Void>? = nil) -> ByteBuffer {
        var buffer = self.allocator.buffer(capacity: byteBufferSize)
        buffer.write(bytes: repeatElement(UInt8(0xff), count: byteBufferSize))
        let frame = HTTP2Frame(streamID: streamID, flags: flags, payload: .data(.byteBuffer(buffer)))

        self.pipeline.write(NIOAny(frame), promise: promise)
        return buffer
    }

    @discardableResult
    func writeDataFrame(_ streamID: HTTP2StreamID, fileRegionSize: Int, flags: HTTP2Frame.FrameFlags = .init(), promise: EventLoopPromise<Void>? = nil) -> FileRegion {
        // We create a deliberately-invalid closed file handle, as we'll never actually use it.
        let handle = FileHandle(descriptor: -1)
        XCTAssertNoThrow(try handle.takeDescriptorOwnership())
        let region = FileRegion(fileHandle: handle, readerIndex: 0, endIndex: fileRegionSize)
        let frame = HTTP2Frame(streamID: streamID, flags: flags, payload: .data(.fileRegion(region)))

        self.pipeline.write(NIOAny(frame), promise: promise)
        return region
    }
}