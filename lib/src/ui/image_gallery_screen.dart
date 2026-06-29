import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../api/filebrowser_client.dart';
import '../api/models.dart';
import 'file_details_sheet.dart';

/// Full-screen, swipeable, pinch-to-zoom photo viewer over the images in a
/// directory. Uses the server's large preview (a transcoded JPEG) so exotic
/// formats (HEIC/RAW/etc.) still display.
class ImageGalleryScreen extends StatefulWidget {
  const ImageGalleryScreen({
    super.key,
    required this.client,
    required this.images,
    required this.initialIndex,
  });

  final FileBrowserClient client;
  final List<FbResource> images;
  final int initialIndex;

  @override
  State<ImageGalleryScreen> createState() => _ImageGalleryScreenState();
}

class _ImageGalleryScreenState extends State<ImageGalleryScreen> {
  late final PageController _pageController;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / ${widget.images.length}  ·  ${widget.images[_index].name}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'Details',
            onPressed: () => FileDetailsSheet.show(
              context,
              resource: widget.images[_index],
              client: widget.client,
            ),
          ),
        ],
      ),
      body: PhotoViewGallery.builder(
        pageController: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (i) => setState(() => _index = i),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        loadingBuilder: (_, __) =>
            const Center(child: CircularProgressIndicator()),
        builder: (context, i) {
          final item = widget.images[i];
          return PhotoViewGalleryPageOptions(
            imageProvider: CachedNetworkImageProvider(
              widget.client.previewUri(item.path, size: 'large').toString(),
              headers: widget.client.authHeaders,
            ),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4,
            heroAttributes: PhotoViewHeroAttributes(tag: item.path),
          );
        },
      ),
    );
  }
}
