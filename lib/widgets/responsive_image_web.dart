import 'package:flutter/material.dart';
import 'dart:ui_web' as ui_web;
import 'dart:html' as html;

/// Web implementation of responsive image using HtmlElementView
Widget buildResponsiveImage(BuildContext context, String url) {
  return Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 800,
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: _buildWebImageView(url),
      ),
    ),
  );
}

Widget _buildWebImageView(String url) {
  // Create unique view type based on URL hash
  final urlHash = url.hashCode.toString();
  final viewType = 'responsive_image_view_$urlHash';

  // Register the view factory if not already registered
  try {
    ui_web.platformViewRegistry.registerViewFactory(
      viewType,
      (int viewId) {
        final imageElement = html.ImageElement()
          ..src = url
          ..style.width = '100%'
          ..style.maxWidth = '800px'
          ..style.maxHeight = '60vh'
          ..style.borderRadius = '12px'
          ..style.objectFit = 'cover'
          ..style.display = 'block';
        
        return imageElement;
      },
    );
  } catch (e) {
    // View factory might already be registered, which is fine
    print("🔄 View factory already registered for $viewType");
  }

  return HtmlElementView(viewType: viewType);
}
