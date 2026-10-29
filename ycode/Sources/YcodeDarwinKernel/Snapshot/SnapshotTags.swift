// Field tags of the snapshot records (specs/simulator/snapshot.md §6.1).
// Shared by the capture and the restore; a tag is never reused for another
// meaning (a reader skips tags it does not know).

enum ST {
    enum System {
        static let lastPID: UInt16 = 1, nextPIDVersion: UInt16 = 2, nextUniqueID: UInt16 = 3, bootSalt: UInt16 = 4
        static let bootSessionUUID: UInt16 = 5, auditSession: UInt16 = 6, serialCounter: UInt16 = 7
        static let stampCounter: UInt16 = 8, spaceCounter: UInt16 = 9, hostBootstrapDefault: UInt16 = 10
        static let hostPort: UInt16 = 11, bootstrapPort: UInt16 = 12, ioKit: UInt16 = 13, fileLocks: UInt16 = 14
        static let shmNames: UInt16 = 15, semNames: UInt16 = 16
        /// The CPU features the snapshot's guests were told (16 bytes,
        /// `CPUFeatureSet.storedBytes`; cpu-features.md §6).
        static let cpuFeatures: UInt16 = 17
    }
    enum Clock {
        static let guestCounter: UInt16 = 1, hostNanoseconds: UInt16 = 2, frequency: UInt16 = 3, bootCounter: UInt16 = 4
        static let wallSeconds: UInt16 = 5
    }
    enum Process {
        static let pid: UInt16 = 1, ppid: UInt16 = 2, pgid: UInt16 = 3, sid: UInt16 = 4, uniqueID: UInt16 = 5
        static let state: UInt16 = 6, status: UInt16 = 7, exitHighBits: UInt16 = 8, image: UInt16 = 9
        static let children: UInt16 = 10, executablePath: UInt16 = 11, comm: UInt16 = 12, name: UInt16 = 13
        static let hasExeced: UInt16 = 14, startSeconds: UInt16 = 15, startMicroseconds: UInt16 = 16
        static let startAbsTime: UInt16 = 17, exitAbsTime: UInt16 = 18, parentUniqueID: UInt16 = 19
        static let originalParentPIDVersion: UInt16 = 20, exiting: UInt16 = 21, continuedPending: UInt16 = 22
        static let continuedBy: UInt16 = 23, dirtyState: UInt16 = 24, processType: UInt16 = 25
        static let processControl: UInt16 = 26, pidVersion: UInt16 = 27, exitReason: UInt16 = 28
        /// A start hold (`scheduling-policy.md` §4.2): ns held so far, the label.
        static let holdElapsed: UInt16 = 29, holdLabel: UInt16 = 30
        static let qosClamp: UInt16 = 31, darwinRole: UInt16 = 32, requestedDarwinBG: UInt16 = 33
    }
    enum Image {
        static let pid: UInt16 = 1, pidVersion: UInt16 = 2, executableHostPath: UInt16 = 3, allImageInfos: UInt16 = 4
        static let allImageInfosSize: UInt16 = 5, mainStackTop: UInt16 = 6, registration: UInt16 = 7
        static let nextActivityID: UInt16 = 8, nextThreadID: UInt16 = 9, purgeable: UInt16 = 10
        static let exitValue: UInt16 = 11, deathSignal: UInt16 = 12, sysctl: UInt16 = 13, extended: UInt16 = 14
        static let ulocks: UInt16 = 15, workqueue: UInt16 = 16, space: UInt16 = 17, descriptors: UInt16 = 18
        static let cwd: UInt16 = 19, maxDescriptors: UInt16 = 20, workqKQueue: UInt16 = 21, workloops: UInt16 = 22
        static let descriptorQueues: UInt16 = 23, mkTimers: UInt16 = 24, executablePath: UInt16 = 25
        static let mainThreadID: UInt16 = 26, timerKnotes: UInt16 = 27, guestSymlinks: UInt16 = 28
    }
    enum Registration {
        static let threadStart: UInt16 = 1, startWorkqueueThread: UInt16 = 2, pthreadSize: UInt16 = 3
        static let dispatchQueueOffset: UInt16 = 4, tsdOffset: UInt16 = 5, returnToKernelOffset: UInt16 = 6
        static let machThreadSelfOffset: UInt16 = 7, joinableOffsetBits: UInt16 = 8, quantumExpiryOffset: UInt16 = 9
    }
    enum Sysctl { static let name: UInt16 = 1, mib: UInt16 = 2, kind: UInt16 = 3, int: UInt16 = 4, size: UInt16 = 5, bytes: UInt16 = 6 }
    enum Extended {
        static let signalMask: UInt16 = 1, pendingSignals: UInt16 = 2, actions: UInt16 = 3, altSP: UInt16 = 4
        static let altSize: UInt16 = 5, altFlags: UInt16 = 6, rlimits: UInt16 = 7, umask: UInt16 = 8
        static let cursors: UInt16 = 9, ioPolicies: UInt16 = 10, threadIOPolicies: UInt16 = 11, backgroundPolicy: UInt16 = 12
        // nested
        static let key: UInt16 = 20, a: UInt16 = 21, b: UInt16 = 22, c: UInt16 = 23, file: UInt16 = 24
        static let names: UInt16 = 25, inodes: UInt16 = 26, types: UInt16 = 27
    }
    enum Thread {
        static let image: UInt16 = 1, threadID: UInt16 = 2, portName: UInt16 = 3, kind: UInt16 = 4
        static let pthreadAddress: UInt16 = 5, signalMask: UInt16 = 6, restoreKind: UInt16 = 7, frame: UInt16 = 8
        static let fp: UInt16 = 9, worker: UInt16 = 10, suspendedStart: UInt16 = 11, note: UInt16 = 12
        static let isMain: UInt16 = 13, mainStart: UInt16 = 14
        /// The process whose importance the thread carries while servicing a message.
        static let carriedImportancePID: UInt16 = 15
    }
    enum Worker {
        static let base: UInt16 = 1, phase: UInt16 = 2, firstRun: UInt16 = 3, qos: UInt16 = 4, constrained: UInt16 = 5
        static let boundQueue: UInt16 = 6, boundBucket: UInt16 = 7, keventRun: UInt16 = 8, delivered: UInt16 = 9
        static let assignment: UInt16 = 10, idle: UInt16 = 11
    }
    enum Start { static let x: UInt16 = 1, pc: UInt16 = 2, sp: UInt16 = 3, tpidrro: UInt16 = 4, tpidr: UInt16 = 5 }
    enum Workqueue {
        static let isOpen: UInt16 = 1, dispatchVersion: UInt16 = 2, serialOffset: UInt16 = 3, labelOffset: UInt16 = 4
        static let hasDispatch: UInt16 = 5, newSPIOffset: UInt16 = 6, managerPriority: UInt16 = 7, idle: UInt16 = 8
        static let plainPending: UInt16 = 9, pendingWorkloops: UInt16 = 10, idleTimeout: UInt16 = 11
        static let qos: UInt16 = 20, overcommit: UInt16 = 21, count: UInt16 = 22
    }
    enum Space {
        static let image: UInt16 = 1, pid: UInt16 = 2, pidVersion: UInt16 = 3, uid: UInt16 = 4, gid: UInt16 = 5
        static let terminated: UInt16 = 6, entries: UInt16 = 7, freeList: UInt16 = 8, nextFresh: UInt16 = 9
        static let taskPort: UInt16 = 10, taskNamePort: UInt16 = 11, taskReadPort: UInt16 = 12, taskInspectPort: UInt16 = 13
        static let mainThreadPort: UInt16 = 14, clockPorts: UInt16 = 15, slots: UInt16 = 16, ownedKernelPorts: UInt16 = 17
        static let specialReplyPorts: UInt16 = 18, threadExceptions: UInt16 = 19, spaceID: UInt16 = 20, isHostTask: UInt16 = 21
        // entry
        static let index: UInt16 = 30, generation: UInt16 = 31, inUse: UInt16 = 32, bits: UInt16 = 33, urefs: UInt16 = 34
        static let port: UInt16 = 35, set: UInt16 = 36, key: UInt16 = 37
    }
    enum Slots {
        static let host: UInt16 = 1, bootstrap: UInt16 = 2, access: UInt16 = 3, debugControl: UInt16 = 4
        static let resourceNotify: UInt16 = 5, registered: UInt16 = 6, exceptions: UInt16 = 7
        static let right: UInt16 = 10, behavior: UInt16 = 11, flavor: UInt16 = 12
    }
    enum Right { static let kind: UInt16 = 1, port: UInt16 = 2 }
    enum Port {
        static let serial: UInt16 = 1, kobjectKind: UInt16 = 2, kobjectValue: UInt16 = 3, semaphore: UInt16 = 4
        static let specialReply: UInt16 = 5, task: UInt16 = 6, fileport: UInt16 = 7, mkTimer: UInt16 = 8
        static let active: UInt16 = 9, receiver: UInt16 = 10, transitHolder: UInt16 = 11, srights: UInt16 = 12
        static let sorights: UInt16 = 13, mscount: UInt16 = 14, seqno: UInt16 = 15, qlimit: UInt16 = 16
        static let context: UInt16 = 17, guarded: UInt16 = 18, strict: UInt16 = 19, immovable: UInt16 = 20
        static let pdRequest: UInt16 = 21, nsRequest: UInt16 = 22, dnRequests: UInt16 = 23, spRequests: UInt16 = 24
        static let deadNameNotified: UInt16 = 25, sets: UInt16 = 26, readyStamp: UInt16 = 27, changeStamp: UInt16 = 28
        static let messages: UInt16 = 29, memoryEntry: UInt16 = 30
        /// Importance (`scheduling-policy.md` §4.3): the port accepts it, is a
        /// temporary owner, and the pid of the job it watches for.
        static let importanceDonation: UInt16 = 31, tempOwner: UInt16 = 32, watchPID: UInt16 = 33
        /// A work-interval port's interval (`WorkInterval.swift`): ID, flags, creator pid.
        static let workIntervalID: UInt16 = 34, workIntervalFlags: UInt16 = 35, workIntervalCreator: UInt16 = 36
        // nested
        static let space: UInt16 = 40, name: UInt16 = 41, armed: UInt16 = 42, timerDeadline: UInt16 = 43
        static let timerTicks: UInt16 = 44, timerArmed: UInt16 = 45, port: UInt16 = 46
    }
    enum PortSet { static let serial: UInt16 = 1, name: UInt16 = 2, members: UInt16 = 3, active: UInt16 = 4, changeStamp: UInt16 = 5 }
    enum Message {
        static let complex: UInt16 = 1, destination: UInt16 = 2, destinationType: UInt16 = 3, reply: UInt16 = 4
        static let replyType: UInt16 = 5, voucher: UInt16 = 6, id: UInt16 = 7, items: UInt16 = 8, inline: UInt16 = 9
        static let aux: UInt16 = 10, hasAux: UInt16 = 11, fromKernel: UInt16 = 12, timerExpiry: UInt16 = 13
        static let sender: UInt16 = 14
        /// The message carries importance; the class of a waiting sender (−1 none).
        static let importance: UInt16 = 15, pushClass: UInt16 = 16
        static let itemKind: UInt16 = 20, right: UInt16 = 21, type: UInt16 = 22, data: UInt16 = 23, copy: UInt16 = 24
        static let volatile: UInt16 = 25, rights: UInt16 = 26, flags: UInt16 = 27
        static let uid: UInt16 = 30, gid: UInt16 = 31, pid: UInt16 = 32, pidVersion: UInt16 = 33, asid: UInt16 = 34
    }
    enum Semaphore { static let count: UInt16 = 1, destroyed: UInt16 = 2 }
    enum ULock { static let address: UInt16 = 1, opcode: UInt16 = 2, owner: UInt16 = 3 }
    enum OpenFile {
        static let nodeKind: UInt16 = 1, stream: UInt16 = 2, file: UInt16 = 3, object: UInt16 = 4, offset: UInt16 = 5
        static let statusFlags: UInt16 = 6, noSigPipe: UInt16 = 7, confined: UInt16 = 8, readEnd: UInt16 = 9
        static let device: UInt16 = 10, lockHandler: UInt16 = 11
    }
    enum HostFile {
        static let guestPath: UInt16 = 1, hostPath: UInt16 = 2, size: UInt16 = 3, mtime: UInt16 = 4, writable: UInt16 = 5
        static let unlinked: UInt16 = 6, content: UInt16 = 7
    }
    enum Pipe {
        static let buffer: UInt16 = 1, readerOpen: UInt16 = 2, writerOpen: UInt16 = 3, atimeS: UInt16 = 4
        static let atimeN: UInt16 = 5, mtimeS: UInt16 = 6, mtimeN: UInt16 = 7
    }
    enum Descriptor { static let fd: UInt16 = 1, file: UInt16 = 2, cloexec: UInt16 = 3, clofork: UInt16 = 4, guardValue: UInt16 = 5, guardFlags: UInt16 = 6 }
    enum KQueue {
        static let kind: UInt16 = 1, fd: UInt16 = 2, legacy: UInt16 = 3, buckets: UInt16 = 4, workloopID: UInt16 = 5
        static let servicer: UInt16 = 6, owner: UInt16 = 7, requested: UInt16 = 8, requestQoS: UInt16 = 9
        static let overcommit: UInt16 = 10, fixedPriority: UInt16 = 11, createReference: UInt16 = 12, knotes: UInt16 = 13
        static let image: UInt16 = 14, hasObject: UInt16 = 15
        static let bucket: UInt16 = 20, boundWorker: UInt16 = 21
    }
    enum Knote {
        static let id: UInt16 = 1, ident: UInt16 = 2, filter: UInt16 = 3, flags: UInt16 = 4, fflags: UInt16 = 5
        static let data: UInt16 = 6, udata: UInt16 = 7, qos: UInt16 = 8, ext: UInt16 = 9, state: UInt16 = 10
        static let bucket: UInt16 = 11, userFlags: UInt16 = 12, timerDeadline: UInt16 = 13, timerInterval: UInt16 = 14
        static let timerFires: UInt16 = 15, procFired: UInt16 = 16, procData: UInt16 = 17, signalCount: UInt16 = 18
        static let object: UInt16 = 19, hostDescriptor: UInt16 = 20, requestsVanish: UInt16 = 21, syncWoken: UInt16 = 22
    }
    enum Region {
        static let image: UInt16 = 1, va: UInt16 = 2, size: UInt16 = 3, protection: UInt16 = 4, kind: UInt16 = 5
        static let guestPath: UInt16 = 6, hostPath: UInt16 = 7, offset: UInt16 = 8, shared: UInt16 = 9, permanent: UInt16 = 10
        static let pages: UInt16 = 11
    }
    enum SharedMemory {
        static let size: UInt16 = 1, file: UInt16 = 2, pages: UInt16 = 3, serial: UInt16 = 4
        static let guestPath: UInt16 = 5, hostPath: UInt16 = 6, offset: UInt16 = 7, requested: UInt16 = 8
    }
    enum Socket {
        static let kind: UInt16 = 1, creator: UInt16 = 2, lastUser: UInt16 = 3, address: UInt16 = 4, boundPath: UInt16 = 5
        static let peer: UInt16 = 6, logSink: UInt16 = 7, flags: UInt16 = 8, error: UInt16 = 9, backlog: UInt16 = 10
        static let pending: UInt16 = 11, listenUser: UInt16 = 12, segments: UInt16 = 13, datagrams: UInt16 = 14
        static let connectedSenders: UInt16 = 15, sendBuffer: UInt16 = 16, receiveBuffer: UInt16 = 17
        static let sendLowWater: UInt16 = 18, receiveLowWater: UInt16 = 19, receiveTimeout: UInt16 = 20
        static let sendTimeout: UInt16 = 21, lingerOn: UInt16 = 22, lingerSeconds: UInt16 = 23, options: UInt16 = 24
        static let peerCredentials: UInt16 = 25
    }
    enum Census { static let name: UInt16 = 1, count: UInt16 = 2, entries: UInt16 = 3 }
}
