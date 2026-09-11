function tests = test_ModularPipelineBuffers
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
testDirectory = fileparts(mfilename('fullpath'));
projectDirectory = fileparts(fileparts(testDirectory));
testCase.applyFixture(matlab.unittest.fixtures.PathFixture(projectDirectory));
end

function testTimebaseUsesExplicitSampleDomains(testCase)
lock = makeLock(3);
timebase = ltesync.Timebase(lock);
first = timebase.currentMeta();
timebase.advance(-1);
second = timebase.currentMeta();
verifyEqual(testCase, first.Epoch, 3);
verifyEqual(testCase, first.RawStartSample0, 1000);
verifyEqual(testCase, second.RawStartSample0, 1000+30720-2);
verifyEqual(testCase, second.SubframeNumber, 1);
verifyEqual(testCase, second.Sequence, 1);
end

function testAssemblerEmitsOnlyCompleteFrame(testCase)
assembler = ltebuffer.CsiFrameAssembler();
for subframe = 0:8
    result = assembler.push(makeSubframe(1, subframe, subframe));
    verifyFalse(testCase, result.Available);
end
result = assembler.push(makeSubframe(1, 9, 9));
verifyTrue(testCase, result.Available);
verifyEqual(testCase, result.Packet.Data.G1, ...
    reshape(repelem(0:9, 2), 1, 20));
verifyEqual(testCase, result.Packet.Meta.EndSequence, 9);
end

function testAssemblerDoesNotBridgeSequenceGap(testCase)
assembler = ltebuffer.CsiFrameAssembler();
for subframe = 0:3
    assembler.push(makeSubframe(1, subframe, subframe));
end
result = assembler.push(makeSubframe(1, 5, 5));
verifyFalse(testCase, result.Available);
verifyEqual(testCase, assembler.BufferedSubframes, 0);
verifyEqual(testCase, assembler.DroppedPartialFrames, 1);
for subframe = 0:9
    result = assembler.push(makeSubframe(1, 10+subframe, subframe));
end
verifyTrue(testCase, result.Available);
verifyEqual(testCase, result.Packet.Meta.Sequence, 10);
end

function testFrameWindowPreservesTimeOrderAndAntennas(testCase)
window = ltebuffer.FrameWindow(3, 3);
for frameIndex = 0:2
    packet = makeFrame(2, frameIndex*10, frameIndex);
    result = window.push(packet, 'G1');
end
verifyTrue(testCase, result.Available);
verifySize(testCase, result.Data, [1, 6, 2]);
verifyEqual(testCase, squeeze(result.Data(1, :, 1)), ...
    [0, 0, 1, 1, 2, 2]);
verifyEqual(testCase, squeeze(result.Data(1, :, 2)), ...
    [100, 100, 101, 101, 102, 102]);
end

function testArKalmanWarmupBypassesAndEpochResets(testCase)
config = defaultLteSenseConfig();
config.Cancellation.ArOrder = 2;
config.Cancellation.WarmupFrames = 6;
canceller = ltecancel.ArKalmanCanceller(config.Cancellation);
for frameIndex = 0:2
    packet = makeCancellationFrame(1, frameIndex*10, frameIndex);
    result = canceller.push(packet);
    verifyTrue(testCase, result.Available);
    verifyFalse(testCase, result.Packet.Meta.CancellationReady);
    verifyEqual(testCase, result.Packet.Data.G1, packet.Data.G1);
end
verifyEqual(testCase, canceller.FrameCount, 3);
packet = makeCancellationFrame(2, 0, 0);
canceller.push(packet);
verifyEqual(testCase, canceller.Epoch, 2);
verifyEqual(testCase, canceller.FrameCount, 1);
end

function lock = makeLock(epoch)
lock = struct('Epoch', epoch, 'RawSampleRateHz', 30.72e6, ...
    'LteSampleRateHz', 15.36e6, 'RawFrameStartSample0', 1000, ...
    'Enb', struct('NFrame', 7));
end

function packet = makeSubframe(epoch, sequence, subframe)
value = double(subframe);
data = struct('G1', value*ones(1, 2), ...
    'G2', (value+20)*ones(1, 2), ...
    'DynamicG1', (value+40)*ones(1, 2), ...
    'DynamicG2', (value+60)*ones(1, 2));
meta = struct('Epoch', epoch, 'Sequence', sequence, ...
    'SubframeNumber', subframe, 'FrameNumber', floor(sequence/10), ...
    'RawStartSample0', sequence*100, ...
    'RawEndSample0', (sequence+1)*100);
packet = struct('Data', data, 'Meta', meta, 'Quality', struct());
end

function packet = makeFrame(receiveCount, sequence, frameIndex)
g1 = zeros(1, 2, receiveCount, 1);
for receive = 1:receiveCount
    g1(:, :, receive, :) = frameIndex+100*(receive-1);
end
data = struct('G1', g1);
meta = struct('Epoch', 1, 'Sequence', sequence, ...
    'EndSequence', sequence+9, 'RawStartSample0', sequence, ...
    'RawEndSample0', sequence+10);
packet = struct('Data', data, 'Meta', meta);
end

function packet = makeCancellationFrame(epoch, sequence, frameIndex)
phase = exp(1i*2*pi*0.13*frameIndex);
g1 = phase*reshape(1:40, 2, 20);
g2 = phase*reshape(41:80, 2, 20);
data = struct('G1', g1, 'G2', g2, ...
    'DynamicG1', 0.1*g1, 'DynamicG2', 0.1*g2);
meta = struct('Epoch', epoch, 'Sequence', sequence, ...
    'EndSequence', sequence+9, 'RawStartSample0', sequence, ...
    'RawEndSample0', sequence+10);
packet = struct('Data', data, 'Meta', meta, 'Quality', struct());
end
