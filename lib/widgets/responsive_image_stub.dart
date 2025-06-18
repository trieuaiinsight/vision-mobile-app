import 'package:flutter/material.dart';

/// Mobile/Desktop implementation of responsive image
Widget buildResponsiveImage(BuildContext context, String url) {
  return Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 800,
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: Icon(Icons.broken_image, size: 48),
            ),
          ),
        ),
      ),
    ),
  );
}
