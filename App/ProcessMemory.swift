#if DEBUG || BLEAT_UI_TESTING
    import Foundation

    /// Captures the process resident memory for performance evidence.
    /// Uses `mach_task_basic_info` which is available on iOS and macOS.
    enum ProcessMemory {
        /// Current resident bytes of the process.
        static var residentBytes: Int64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(
                MemoryLayout<mach_task_basic_info>.stride
                    / MemoryLayout<integer_t>.stride
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(
                    to: integer_t.self,
                    capacity: Int(count)
                ) { rebound in
                    task_info(
                        mach_task_self_,
                        task_flavor_t(MACH_TASK_BASIC_INFO),
                        rebound,
                        &count
                    )
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Int64(info.resident_size)
        }
    }
#endif
