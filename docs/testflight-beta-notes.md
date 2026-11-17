# TestFlight beta 0.3.0 (5)

Copy these descriptions into App Store Connect when the build is available. Feedback email and review contact details are configured in App Store Connect, not in this file. This beta uses email invitations with no public link, app account, subscription, or invitation-code requirement.

## Beta App Description — English

Photons Studio is a local photo editor for Apple Silicon Macs, with RAW import, HDR and SDR preview and export, panorama stitching, and lens cast correction (LCC). It supports Chinese and English and manages photos in local libraries. This development beta focuses on image quality, compatibility, performance, and sandbox file access.

## What to Test — English

- Create or open a library, import RAW, DNG, TIFF, and HEIF photos, and check preview generation, orientation, thumbnail aspect ratios, and duplicate-import options.
- Edit an image, switch HDR/SDR preview, inspect the histogram, undo edits, and reset to the imported state.
- Stitch overlapping photos, check the alignment preview, then export. Confirm that progress appears in the main window and that the finished panorama is imported into the library.
- Try lens-profile LCC on single images and panoramas, including panoramas exported before applying LCC. Compare against correction during stitching; some post-export corrections are approximate.
- Export HDR/SDR images and losslessly compressed DNGs. Compare color, brightness, metadata, and embedded previews in other applications.
- Check folder permissions after restarting, source-folder exports, language settings, library management, and preview-cache settings.

Please include the steps, file format, Mac model, display type, and whether HDR preview was enabled when reporting a problem. Test with copies of valuable photos. Apple Silicon and macOS 14 or later are required; Intel Macs are not supported by this build.

## Beta App Description — 简体中文

Photons Studio 是面向 Apple Silicon Mac 的本地照片编辑器，支持 RAW 导入、HDR/SDR 预览和导出、全景拼接及镜头色偏校正（LCC），提供中英文界面与本地照片库管理。本开发测试版主要收集图像质量、格式兼容性、性能与沙盒文件访问方面的反馈。

## What to Test — 简体中文

- 创建或打开照片库，导入 RAW、DNG、TIFF、HEIF，检查初始预览、方向、缩略图长宽比及重复导入选项。
- 编辑照片，切换 HDR/SDR 预览，检查直方图、撤销历史及还原到导入状态。
- 拼接有重叠的照片，检查对齐预览并导出；确认主界面显示进度，完成后自动导入拼接结果。
- 对单张和全景图进行镜头配置文件 LCC 校正，对比拼接时校正与导出后校正；部分导出后校正属于近似结果。
- 导出 HDR/SDR 图片及无损压缩 DNG，在其他软件检查颜色、亮度、元数据及嵌入预览。
- 检查重启后的目录权限、原照片文件夹导出、语言设置、照片库管理及预览缓存设置。

反馈请附操作步骤、文件格式、Mac 型号、显示器类型，以及是否开启 HDR 预览。建议使用重要照片的副本测试。本构建要求 Apple Silicon 和 macOS 14 或更新版本，不支持 Intel Mac。

## Review Notes — English

No app login, subscription, or invitation code is required. The app processes photos locally. Create a library in a user-selected folder and import photos using the import control. macOS file-access prompts authorize those user-selected locations. Open an image to edit it; select overlapping photos and use Control-M to open panorama stitching. The application includes separately executed image-processing helpers and their corresponding open-source licenses/source materials in the application bundle.
