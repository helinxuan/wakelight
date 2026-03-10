import CoreLocation

enum GeoCoordinateTransform {
    // WGS-84 <-> GCJ-02 transform
    private static let a: Double = 6378245.0
    private static let ee: Double = 0.00669342162296594323

    static func wgs84ToGcj02IfNeeded(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return wgs84ToGcj02(latitude: latitude, longitude: longitude)
    }

    static func gcj02ToWgs84IfNeeded(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        return gcj02ToWgs84(latitude: latitude, longitude: longitude)
    }

    static func wgs84ToGcj02(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        var dLat = transformLat(x: longitude - 105.0, y: latitude - 35.0)
        var dLon = transformLon(x: longitude - 105.0, y: latitude - 35.0)
        let radLat = latitude / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Double.pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * Double.pi)
        let mgLat = latitude + dLat
        let mgLon = longitude + dLon
        return CLLocationCoordinate2D(latitude: mgLat, longitude: mgLon)
    }

    static func gcj02ToWgs84(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
        if isOutOfChina(latitude: latitude, longitude: longitude) {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        let gcj = wgs84ToGcj02(latitude: latitude, longitude: longitude)
        let dLat = gcj.latitude - latitude
        let dLon = gcj.longitude - longitude
        return CLLocationCoordinate2D(latitude: latitude - dLat, longitude: longitude - dLon)
    }

    static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        if longitude < 72.004 || longitude > 137.8347 { return true }
        if latitude < 0.8293 || latitude > 55.8271 { return true }
        return false
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * Double.pi) + 320.0 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return ret
    }
}
