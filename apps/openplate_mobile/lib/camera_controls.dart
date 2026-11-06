import 'package:flutter/material.dart';

enum CameraStatusTone { active, pending, muted, error }

class CameraStatusItem {
  const CameraStatusItem(this.icon, this.label, this.value, this.tone);
  final IconData icon;
  final String label;
  final String value;
  final CameraStatusTone tone;
}

/// Camera controls remain separate from capture and recognition lifecycle.
class CameraControls extends StatelessWidget {
  const CameraControls({
    required this.paired,
    required this.blackMode,
    required this.statusLabel,
    required this.statusTone,
    required this.statuses,
    required this.onBack,
    required this.onToggleBlackMode,
    required this.details,
    this.notice,
    this.lastPlate,
    this.motionStatus,
    this.vehicleLabel,
    this.vehicleActions = const [],
    this.onRetry,
    this.onToggleLegacyLive,
    this.legacyStreaming = false,
    super.key,
  });

  final bool paired;
  final bool blackMode;
  final String statusLabel;
  final CameraStatusTone statusTone;
  final List<CameraStatusItem> statuses;
  final VoidCallback onBack;
  final VoidCallback onToggleBlackMode;
  final Map<String, String> details;
  final String? notice;
  final String? lastPlate;
  final String? motionStatus;
  final String? vehicleLabel;
  final List<Widget> vehicleActions;
  final VoidCallback? onRetry;
  final VoidCallback? onToggleLegacyLive;
  final bool legacyStreaming;

  Color _color(BuildContext context, CameraStatusTone tone) => switch (tone) {
    CameraStatusTone.active => const Color(0xFF8DE1B0),
    CameraStatusTone.pending => const Color(0xFFFFD287),
    CameraStatusTone.error => Theme.of(context).colorScheme.error,
    CameraStatusTone.muted => const Color(0xFF99A8B8),
  };

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            const SizedBox(height: 16),
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: size.maxHeight * .72),
                  child: SingleChildScrollView(
                    key: const Key('camera-status-scroll'),
                    child: _panel(context),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _backButton() => IconButton.filledTonal(
    onPressed: onBack,
    tooltip: 'Zur Übersicht',
    style: IconButton.styleFrom(
      backgroundColor: const Color(0xF2151E29),
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    icon: const Icon(Icons.chevron_left_rounded, size: 28),
  );

  Widget _badge(BuildContext context) => Semantics(
    label: 'Kamerastatus: $statusLabel',
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xF2151E29),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _color(context, statusTone),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            statusLabel,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: _color(context, statusTone),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _title(BuildContext context) => Text(
    paired ? 'Live-Kamera' : 'Kamera-Vorschau',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
  );

  Widget _header(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final compact =
          size.maxWidth < 330 ||
          MediaQuery.textScalerOf(context).scale(14) > 18;
      if (compact) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _backButton(),
                const SizedBox(width: 12),
                Expanded(child: _title(context)),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 60, top: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _badge(context),
              ),
            ),
          ],
        );
      }
      return Row(
        children: [
          _backButton(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _title(context),
                Text(
                  paired ? 'Automatischer Betrieb' : 'Noch nicht gekoppelt',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFCAD4DF),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _badge(context),
        ],
      );
    },
  );

  Widget _panel(BuildContext context) => Material(
    color: const Color(0xF5151E29),
    borderRadius: BorderRadius.circular(24),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                paired
                    ? Icons.auto_awesome_outlined
                    : Icons.visibility_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  paired ? 'Alles startet automatisch' : 'Lokale Vorschau',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final status in statuses) _statusRow(context, status),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                notice!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFFFFD287)),
              ),
            ),
          if (!paired)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Home Assistant per QR-Code koppeln, um Erkennung und Livebild zu nutzen.',
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1),
          ),
          Text(
            'LETZTES KENNZEICHEN',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.3,
              color: const Color(0xFF99A8B8),
            ),
          ),
          const SizedBox(height: 8),
          if (lastPlate != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F4F8),
                borderRadius: BorderRadius.circular(8),
                border: const Border(
                  left: BorderSide(color: Color(0xFF2455B2), width: 9),
                ),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    lastPlate!,
                    style: const TextStyle(
                      color: Color(0xFF0B1118),
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
            )
          else
            Text(
              paired ? 'Warte auf eine Erkennung …' : 'Noch keine Erkennung',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFFCAD4DF)),
            ),
          if (lastPlate != null && motionStatus != null) ...[
            const SizedBox(height: 8),
            Text(motionStatus!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (vehicleLabel != null)
            Text(
              'Fahrzeug: $vehicleLabel',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ...vehicleActions,
          if (onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Kamera erneut starten'),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onToggleBlackMode,
            icon: Icon(
              blackMode ? Icons.visibility_outlined : Icons.dark_mode_outlined,
            ),
            label: Text(blackMode ? 'Vorschau anzeigen' : 'Schwarzmodus'),
          ),
          if (onToggleLegacyLive != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                onPressed: onToggleLegacyLive,
                icon: Icon(
                  legacyStreaming
                      ? Icons.videocam_off_outlined
                      : Icons.videocam_outlined,
                ),
                label: Text(
                  legacyStreaming
                      ? 'HA-Livebild stoppen'
                      : 'HA-Livebild starten',
                ),
              ),
            ),
          if (paired)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Livebild und Einstellungen in Home Assistant verwalten.',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF99A8B8)),
              ),
            ),
          if (blackMode)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Bedienung wird nach 8 Sekunden ausgeblendet.',
                textAlign: TextAlign.center,
              ),
            ),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('Details', style: TextStyle(fontSize: 13)),
              children: [
                for (final detail in details.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${detail.key}: ${detail.value}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _statusRow(BuildContext context, CameraStatusItem status) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _color(context, status.tone).withValues(alpha: .10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            status.icon,
            size: 18,
            color: _color(context, status.tone),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status.label,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: const Color(0xFF99A8B8)),
              ),
              Text(
                status.value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: _color(context, status.tone),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
