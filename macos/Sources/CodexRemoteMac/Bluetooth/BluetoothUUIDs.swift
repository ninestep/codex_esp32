import CoreBluetooth

public enum BluetoothUUIDs {
    public static var service: CBUUID { CBUUID(string: "7D2E0000-7C6A-4E6D-A3E1-9F6B4C520001") }
    public static var controlToHost: CBUUID { CBUUID(string: "7D2E0001-7C6A-4E6D-A3E1-9F6B4C520001") }
    public static var controlToDevice: CBUUID { CBUUID(string: "7D2E0002-7C6A-4E6D-A3E1-9F6B4C520001") }
    public static var stateToDevice: CBUUID { CBUUID(string: "7D2E0003-7C6A-4E6D-A3E1-9F6B4C520001") }
    public static var audioToHost: CBUUID { CBUUID(string: "7D2E0004-7C6A-4E6D-A3E1-9F6B4C520001") }
    public static var assetToDevice: CBUUID { CBUUID(string: "7D2E0005-7C6A-4E6D-A3E1-9F6B4C520001") }
    public static var deviceInfo: CBUUID { CBUUID(string: "7D2E0006-7C6A-4E6D-A3E1-9F6B4C520001") }
}
