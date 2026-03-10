import Foundation

#if canImport(MatrixRustSDK)
import MatrixRustSDK
#endif

public enum MatrixSDKBridge {
    public static var isLinked: Bool {
        #if canImport(MatrixRustSDK)
        true
        #else
        false
        #endif
    }
}

