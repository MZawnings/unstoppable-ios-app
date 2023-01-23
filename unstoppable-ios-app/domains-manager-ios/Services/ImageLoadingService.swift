//
//  ImageLoadingService.swift
//  domains-manager-ios
//
//  Created by Oleg Kuplin on 29.04.2022.
//

import UIKit

protocol ImageLoadingServiceProtocol {
    func loadImage(from source: ImageSource, downsampleDescription: DownsampleDescription?) async -> UIImage?
    func cachedImage(for source: ImageSource) -> UIImage?
    func downsample(image: UIImage, downsampleDescription: DownsampleDescription) -> UIImage?
    func storeImage(_ image: UIImage, for source: ImageSource) async
    func getStoredImage(for source: ImageSource) -> UIImage?
    func clearCache() async
    func clearStoredImages() async
}
// MARK: - DownsampleDescription
struct DownsampleDescription {
    let size: CGSize
    let scale: CGFloat
}

enum ImageSource {
    case url(_ url: URL)
    case initials(_ name: String, size: InitialsView.InitialsSize, style: InitialsView.Style)
    case domain(_ domainItem: DomainItem)
    case domainInitials(_ domainItem: DomainItem, size: InitialsView.InitialsSize)
    case domainItemOrInitials(_ domainItem: DomainItem, size: InitialsView.InitialsSize)
    case currency(_ currency: CoinRecord, size: InitialsView.InitialsSize, style: InitialsView.Style)
    case wcApp(_ appInfo: WalletConnectService.WCServiceAppInfo, size: InitialsView.InitialsSize)
    case connectedApp(_ connectedApp: any UnifiedConnectAppInfoProtocol, size: InitialsView.InitialsSize)
    case qrCode(url: URL, options: [QRCodeService.Options])

    var key: String {
        switch self {
        case .url(let url):
            return url.absoluteString
        case .initials(let name, let initialsSize, let style):
            let initials = String(name.first ?? .init("")).uppercased()
            return initials + "_\(initialsSize.rawValue)_\(style.rawValue)"
        case .domain(let domainItem):
            return domainItem.pfpInfo.value
        case .domainInitials(let domainItem, let size):
            return ImageSource.initials(domainItem.name, size: size, style: .accent).key
        case .domainItemOrInitials(let domainItem, let size):
            if domainItem.pfpInfo != .none {
                return ImageSource.domain(domainItem).key
            }
            return ImageSource.domainInitials(domainItem, size: size).key
        case .currency(let currency, let size, let style):
            return currency.ticker + "_\(size.rawValue)_\(style.rawValue)"
        case .wcApp(let appInfo, let size):
            return appInfo.getDisplayName() + "_\(size.rawValue)"
        case .connectedApp(let appInfo, let size):
            return appInfo.displayName + "_\(size.rawValue)"
        case .qrCode(let url, let options):
            let urlKey = ImageSource.url(url).key
            let optionsKey = options.sorted(by: { $0.rawValue < $1.rawValue }).map({ "\($0.rawValue)" }).joined(separator: "_")
            return urlKey + "_" + optionsKey
        }
    }
}

actor ImageLoadingService {
        
    private let qrCodeService: QRCodeServiceProtocol
    private let storage = ImagesStorage()
    private let imageCache = NSCache<NSString, UIImage>()
    private var cacheKeys = Set<String>()
    private var currentAsyncProcess = [String : Task<UIImage?, Never>]()
    
    init(qrCodeService: QRCodeServiceProtocol) {
        self.qrCodeService = qrCodeService
        imageCache.totalCostLimit = 50_000_000 // 50 MB
    }
    
}

// MARK: - ImageLoadingManagerProtocol
extension ImageLoadingService: ImageLoadingServiceProtocol {
    // Currently downsample description is ignored. We set maximum size of upcoming image to 512px.
    func loadImage(from source: ImageSource, downsampleDescription: DownsampleDescription?) async -> UIImage? {
        let key = source.key
        if let cachedImage = self.imageCache.object(forKey: key as NSString) {
            return cachedImage
        }
        
        if let imageTask = currentAsyncProcess[key] {
            return await imageTask.value
        }
        
        let task: Task<UIImage?, Never> = Task.detached(priority: .medium) {
            if let storedImage = self.getStoredImage(for: key) {
                return storedImage
            }
            
            if let image = await self.imageFor(source: source, downsampleDescription: downsampleDescription) {
                return image
            } else {
                return nil
            }
        }
        
        currentAsyncProcess[key] = task
        let image = await task.value
        currentAsyncProcess[key] = nil
        
        return image
    }
    
    nonisolated
    func downsample(image: UIImage, downsampleDescription: DownsampleDescription) -> UIImage? {
        guard let imageData = image.jpegData(compressionQuality: 1) else { return nil }
        
        return downsample(imageData: imageData, downsampleDescription: downsampleDescription)
    }
    
    func storeImage(_ image: UIImage, for source: ImageSource) async {
        guard let imageData = image.jpegData(compressionQuality: 1) ?? image.pngData() else { return }
        
        storage.storeImageData(imageData, for: source.key)
    }
    
    nonisolated
    func cachedImage(for source: ImageSource) -> UIImage? {
        cachedImage(for: source.key)
    }
   
    nonisolated
    func getStoredImage(for source: ImageSource) -> UIImage? {
        getStoredImage(for: source.key)
    }
  
    func clearCache() async {
        imageCache.removeAllObjects()
    }
    
    func clearStoredImages() async {
        storage.clearStoredImages()
    }
}

// MARK: - Private methods
fileprivate extension ImageLoadingService {
    func imageFor(source: ImageSource, shouldCache: Bool = true, downsampleDescription: DownsampleDescription?) async -> UIImage? {
        switch source {
        case .url(let url):
            do {
                let imageData = try await loadImage(from: url)
                
                return autoreleasepool {
                    var finalImage: UIImage?
                  
                    let maxImageSize: CGFloat = Constants.ImagesMaxSize
                    if let image = UIImage(data: imageData) {
                        finalImage = scaleIfNeeded(image, maxImageSize: maxImageSize)
                    } else {
                        finalImage = scaleIfNeeded(UIImage.from(svgData: imageData), maxImageSize: maxImageSize)
                    }
                    
                    guard let image = finalImage else { return nil }
                    
                    if shouldCache {
                        storeAndCache(image: image, forKey: source.key)
                    }
                    
                    return image
                }
            } catch {
                return nil
            }
        case .initials(let initials, let size, let style):
            if let cachedImage = self.imageCache.object(forKey: source.key as NSString) {
                return cachedImage
            }
            if let image = await InitialsView(initials: initials, size: size, style: style).toInitialsImage() {
                self.cache(image: image, forKey: source.key)
                return image
            }
            return nil
        case .domain(let domainItem):
            switch domainItem.pfpInfo {
            case .nft(let imagePath), .nonNFT(let imagePath):
                guard let url = URL(string: imagePath) else { return nil }
                let start = Date()
                
                if let image = await imageFor(source: .url(url), downsampleDescription: downsampleDescription) {
                    Debugger.printWarning("\(String.itTook(from: start)) to load domain pfp")
                    return image
                }
                return nil
            case .none:
                return nil
            }
        case .domainInitials(let domainItem, let size):
            return await imageFor(source: .initials(domainItem.name, size: size, style: .accent), downsampleDescription: downsampleDescription)
        case .domainItemOrInitials(let domainItem, let size):
            if domainItem.pfpInfo != .none,
               let image = await imageFor(source: .domain(domainItem), downsampleDescription: downsampleDescription) {
                return image
            }
            return await imageFor(source: .domainInitials(domainItem, size: size), downsampleDescription: downsampleDescription)
        case .currency(let currency, let size, let style):
            if let url = URL(string: NetworkConfig.currencyIconUrl(for: currency)),
               let image = await loadAndCacheImage(from: url, forKey: source.key, withMaxImageSize: Constants.IconsMaxSize) {
                return image
            }
            return await imageFor(source: .initials(currency.ticker, size: size, style: style), downsampleDescription: downsampleDescription)
        case .wcApp(let appInfo, let size):
            if let url = appInfo.getIconURL(),
               let image = await loadAndCacheImage(from: url, forKey: source.key, withMaxImageSize: Constants.IconsMaxSize) {
                return image
            }
            return await imageFor(source: .initials(appInfo.getDisplayName(), size: size, style: .gray), downsampleDescription: downsampleDescription)
        case .connectedApp(let appInfo, let size):
            let urlString = appInfo.appIconUrls
                .first(where: { URL(string: $0).pathExtensionPng }) ?? appInfo.appIconUrls.first
            if let urlString = urlString,
               let url = URL(string: urlString),
               let image = await loadAndCacheImage(from: url, forKey: source.key, withMaxImageSize: Constants.IconsMaxSize) {
                return image
            }
            return await imageFor(source: .initials(appInfo.displayName, size: size, style: .gray), downsampleDescription: downsampleDescription)
        case .qrCode(let url, let options):
            if let image = try? await qrCodeService.generateUDQRCode(for: url,
                                                                     with: options),
               let scaledImage = scaleIfNeeded(image, maxImageSize: Constants.ImagesMaxSize) {
                storeAndCache(image: scaledImage, forKey: source.key)
                return scaledImage
            }
            return nil
        }
    }
    
    func loadAndCacheImage(from url: URL, forKey key: String, withMaxImageSize maxImageSize: CGFloat) async -> UIImage? {
        if let image = await imageFor(source: .url(url), shouldCache: false, downsampleDescription: nil),
           let scaledImage = scaleIfNeeded(image, maxImageSize: maxImageSize) {
            storeAndCache(image: scaledImage, forKey: key)
            return scaledImage
        }
        return nil
    }
    
    func scaleIfNeeded(_ image: UIImage?, maxImageSize: CGFloat) -> UIImage? {
        guard let image else { return nil }
        
        let scale = image.scale
        if ((image.size.width * scale) > maxImageSize || (image.size.height * scale) > maxImageSize),
           let imageData = image.pngData() {
            return downsample(imageData: imageData,
                              downsampleDescription: .init(size: CGSize(width: maxImageSize,
                                                                        height: maxImageSize),
                                                           scale: 1))
        } else {
            return image
        }
    }
    
    func loadImage(from url: URL) async throws -> Data {
        if #available(iOS 15.0, *) {
            let urlRequest = URLRequest(url: url)
            let (imageData, _) = try await URLSession.shared.data(for: urlRequest)
            return imageData
        } else {
            return try await withSafeCheckedThrowingContinuation { completion in
                Task.detached {
                    do {
                        let imageData = try Data(contentsOf: url)
                        completion(.success(imageData))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    nonisolated
    func cachedImage(for key: String) -> UIImage? {
        self.imageCache.object(forKey: key as NSString)
    }
    
    nonisolated
    func getStoredImage(for key: String) -> UIImage? {
        if let cachedImage = cachedImage(for: key) {
            return cachedImage
        }
        guard let imageData = storage.getStoredImage(for: key) else { return nil }
        
        if let image = UIImage(data: imageData) {
            Task { await cache(image: image, forKey: key) }
            return image
        }
        return nil
    }
    
    func storeAndCache(image: UIImage, forKey key: String) {
        if let imageData = image.pngData() {
            storage.storeImageData(imageData, for: key)
        } else if let imageData = image.jpegData(compressionQuality: 1) {
            storage.storeImageData(imageData, for: key)
        }
        cache(image: image, forKey: key)
    }
    
    func cache(image: UIImage, forKey key: String) {
        self.imageCache.setObject(image, forKey: key as NSString)
        #if DEBUG
        self.cacheKeys.insert(key)
        let cacheSize = cacheKeys.compactMap({ imageCache.object(forKey: $0 as NSString)?.size }).map({ $0.width * $0.height * 4 }).reduce(0, { $0 + $1 })
        Debugger.printInfo("Did cache image with size \(image.size) for key \(key)\nCurrent images cache memory usage: \(cacheSize)")
        #endif
    }
    
    func downsample(imageAt imageURL: URL, to size: CGSize, scale: CGFloat) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions) else { return nil }
        
        return createThumbnail(from: imageSource, size: size, scale: scale)
    }
    
    nonisolated
    func downsample(imageData: Data, downsampleDescription: DownsampleDescription) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        return imageData.withUnsafeBytes { (unsafeRawBufferPointer: UnsafeRawBufferPointer) -> UIImage? in
            let unsafeBufferPointer = unsafeRawBufferPointer.bindMemory(to: UInt8.self)
            
            guard let unsafePointer = unsafeBufferPointer.baseAddress else { return nil }
            guard let data = CFDataCreate(kCFAllocatorDefault, unsafePointer, imageData.count) else { return nil }
            guard let imageSource = CGImageSourceCreateWithData(data, imageSourceOptions) else { return nil }
            
            return createThumbnail(from: imageSource, size: downsampleDescription.size, scale: downsampleDescription.scale)
        }
    }
    
    nonisolated
    private func createThumbnail(from imageSource: CGImageSource, size: CGSize, scale: CGFloat) -> UIImage? {
        let maxDimensionInPixels = max(size.width, size.height) * scale
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options) else { return nil }
        
        return UIImage(cgImage: thumbnail)
    }
}