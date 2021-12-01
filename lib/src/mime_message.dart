import 'dart:typed_data';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:enough_mail/src/codecs/date_codec.dart';
import 'package:enough_mail/src/codecs/mail_codec.dart';
import 'package:enough_mail/src/imap/message_sequence.dart';
import 'package:enough_mail/src/mail_address.dart';
import 'package:enough_mail/src/mail_conventions.dart';
import 'package:enough_mail/src/media_type.dart';
import 'package:enough_mail/src/message_flags.dart';
import 'package:enough_mail/src/mime_data.dart';
import 'package:enough_mail/src/private/imap/parser_helper.dart';
import 'package:enough_mail/src/private/util/ascii_runes.dart';
import 'package:enough_mail/src/private/util/mail_address_parser.dart';

/// A MIME part
/// In a simple case a MIME message only has one MIME part.
class MimePart {
  /// The `headers` field contains all message(part) headers
  List<Header>? headers;

  /// The raw message data of this part. May or may not include headers, depending on retrieval.
  MimeData? mimeData;

  /// The children of this part, if any.
  ///
  List<MimePart>? parts;

  bool _isParsed = false;
  String? _decodedText;
  DateTime? _decodedDate;
  ContentTypeHeader? _contentTypeHeader;
  ContentDispositionHeader? _contentDispositionHeader;

  /// Simplified way to retrieve the media type
  /// When no `content-type` header is defined, the media type `text/plain` is returned
  MediaType get mediaType {
    final header = getHeaderContentType();
    return header?.mediaType ?? MediaType.textPlain;
  }

  /// Retrieves the raw value of the first matching header.
  ///
  /// Some headers may contain encoded values such as '=?utf-8?B?<data>?='.
  /// Compare [decodeHeaderValue] for retrieving the header value in decoded form.
  /// Compare [getHeader] for retrieving the full header with the given name.
  String? getHeaderValue(String name) {
    return _getLowerCaseHeaderValue(name.toLowerCase());
  }

  /// Retrieves the raw value of the first matching header.
  ///
  /// Some headers may contain encoded values such as '=?utf-8?B?<data>?='.
  /// Compare [decodeHeaderValue] for retrieving the header value in decoded form.
  /// Compare [getHeader] for retrieving the full header with the given name.
  String? _getLowerCaseHeaderValue(String name) {
    final matchingHeaders = _getHeaderLowercase(name);
    if (matchingHeaders?.isNotEmpty ?? false) {
      return matchingHeaders!.first.value;
    }
    return null;
  }

  /// Checks if this MIME part has a header with the specified [name].
  bool hasHeader(String name) => _hasHeaderLowercase(name.toLowerCase());

  bool _hasHeaderLowercase(String name) {
    if (!_isParsed) {
      parse();
    }
    return (headers?.firstWhereOrNull((h) => h.lowerCaseName == name) != null);
  }

  /// Retrieves all matching headers with the specified [name].
  Iterable<Header>? getHeader(String name) =>
      _getHeaderLowercase(name.toLowerCase());

  Iterable<Header>? _getHeaderLowercase(String name) {
    if (!_isParsed) {
      parse();
    }
    return headers?.where((h) => h.lowerCaseName == name);
  }

  /// Adds a header with the specified [name], [value] and optional [encoding].
  void addHeader(String name, String? value,
      [HeaderEncoding encoding = HeaderEncoding.none]) {
    headers ??= <Header>[];
    var localValue = value;
    if (value != null) {
      if (encoding == HeaderEncoding.Q) {
        localValue = MailCodec.quotedPrintable
            .encodeHeader(value, nameLength: name.length);
      } else if (encoding == HeaderEncoding.B) {
        localValue =
            MailCodec.base64.encodeHeader(value, nameLength: name.length);
      }
    }
    final header = Header(name, localValue, encoding);
    headers!.add(header);
  }

  /// Sets a header with the specified [name], [value] and optional [encoding], replacing any existing header with the same [name].
  void setHeader(String name, String? value,
      [HeaderEncoding encoding = HeaderEncoding.none]) {
    headers ??= <Header>[];
    final lowerCaseName = name.toLowerCase();
    headers!.removeWhere((h) => h.lowerCaseName == lowerCaseName);
    var localValue = value;
    if (value != null) {
      if (encoding == HeaderEncoding.Q) {
        localValue = MailCodec.quotedPrintable
            .encodeHeader(value, nameLength: name.length);
      } else if (encoding == HeaderEncoding.B) {
        localValue =
            MailCodec.base64.encodeHeader(value, nameLength: name.length);
      }
    }
    headers!.add(Header(name, localValue, encoding));
  }

  /// Removes the header with the specified [name].
  void removeHeader(String name) {
    headers ??= <Header>[];
    final lowerCaseName = name.toLowerCase();
    headers!.removeWhere((h) => h.lowerCaseName == lowerCaseName);
  }

  void insertPart(MimePart part) {
    parts ??= <MimePart>[];
    parts!.insert(0, part);
  }

  void addPart(MimePart part) {
    parts ??= <MimePart>[];
    parts!.add(part);
  }

  /// Retrieves the first 'content-type' header.
  ContentTypeHeader? getHeaderContentType() {
    if (_contentTypeHeader == null) {
      final value = _getLowerCaseHeaderValue('content-type');
      if (value == null) {
        return null;
      }
      _contentTypeHeader = ContentTypeHeader(value);
    }
    return _contentTypeHeader;
  }

  /// Retrieves the first 'content-disposition' header.
  ContentDispositionHeader? getHeaderContentDisposition() {
    if (_contentDispositionHeader != null) {
      return _contentDispositionHeader;
    }
    final value = _getLowerCaseHeaderValue('content-disposition');
    if (value == null) {
      return null;
    }
    _contentDispositionHeader = ContentDispositionHeader(value);
    return _contentDispositionHeader;
  }

  /// Adds the matching disposition header with the specified [disposition] of this part and this children parts to the [result].
  ///
  /// Optionally set [reverse] to `true` to add all parts that do not match the specified `disposition`.
  /// Set [complete] to `false` to skip the included messages parts.
  void collectContentInfo(
      ContentDisposition disposition, List<ContentInfo> result, String? fetchId,
      {bool? reverse, bool? complete}) {
    reverse ??= false;
    complete ??= true;
    final header = getHeaderContentDisposition();
    final isMessage = getHeaderContentType()?.mediaType.isMessage ?? false;
    if ((!reverse && header?.disposition == disposition) ||
        (reverse && header?.disposition != disposition)) {
      final info = ContentInfo(fetchId ?? '')
        ..contentDisposition = header
        ..contentType = getHeaderContentType()
        ..cid = _getLowerCaseHeaderValue('content-id');
      result.add(info);
    }
    if (complete || !isMessage) {
      if (parts?.isNotEmpty ?? false) {
        for (var i = 0; i < parts!.length; i++) {
          final part = parts![i];
          final partFetchId = mediaType.sub == MediaSubtype.messageRfc822
              ? fetchId
              : fetchId != null
                  ? '$fetchId.${i + 1}'
                  : '${i + 1}';
          part.collectContentInfo(disposition, result, partFetchId,
              reverse: reverse, complete: complete);
        }
      }
    }
  }

  /// Decodes the value of the first matching header
  String? decodeHeaderValue(String name) {
    final value = getHeaderValue(name);
    try {
      return MailCodec.decodeHeader(value);
    } catch (e) {
      print('Unable to decode header [$name: $value]: $e');
      return value;
    }
  }

  /// Decodes the message 'date' header to local time.
  DateTime? decodeDate() {
    _decodedDate ??= decodeHeaderDateValue('date');
    return _decodedDate;
  }

  /// Tries to find and decode the associated file name
  String? decodeFileName() {
    final fileName = MailCodec.decodeHeader(
        (getHeaderContentDisposition()?.filename ??
            getHeaderContentType()?.parameters['name']));
    return fileName?.replaceAll('\\"', '"');
  }

  /// Decodes the a date value of the first matching header
  DateTime? decodeHeaderDateValue(String name) {
    return DateCodec.decodeDate(getHeaderValue(name));
  }

  /// Decodes the email address value of first matching header
  List<MailAddress>? decodeHeaderMailAddressValue(String name) {
    return MailAddressParser.parseEmailAddreses(getHeaderValue(name));
  }

  /// Decodes the text of this part.
  String? decodeContentText() {
    _decodedText ??= mimeData?.decodeText(
      getHeaderContentType(),
      _getLowerCaseHeaderValue('content-transfer-encoding'),
    );
    return _decodedText;
  }

  /// Decodes the binary data of this part.
  Uint8List? decodeContentBinary() {
    return mimeData?.decodeBinary(
      _getLowerCaseHeaderValue('content-transfer-encoding'),
    );
  }

  /// Decodes a message/rfc822 part
  MimeMessage? decodeContentMessage() {
    final data = mimeData;
    if (data == null) {
      return null;
    }
    final message = MimeMessage()..mimeData = data.decodeMessageData();
    message.parse();
    return message;
  }

  /// Checks if this MIME part is textual.
  bool isTextMediaType() {
    return mediaType.isText;
  }

  /// Checks if this MIME part or a child is textual.
  ///
  /// [depth] optional depth, use 1 if only direct children should be checked
  bool hasTextPart({int? depth}) {
    if (isTextMediaType()) {
      return true;
    }
    if (parts != null) {
      if (depth != null) {
        if (--depth < 0) {
          return false;
        }
      }
      for (final part in parts!) {
        if (part.hasTextPart(depth: depth)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Checks if this MIME part or a child is of the specified media type
  ///
  /// [subtype] the desired media type
  /// [depth] optional depth, use 1 if only direct children should be checked
  bool hasPart(MediaSubtype subtype, {int? depth}) {
    if (mediaType.sub == subtype) {
      return true;
    }
    final mimeParts = parts;
    if (mimeParts != null) {
      if (depth != null) {
        if (--depth < 0) {
          return false;
        }
      }
      for (final part in mimeParts) {
        if (part.hasPart(subtype, depth: depth)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Searches the MimePart with the specified [subtype].
  MimePart? getPartWithMediaSubtype(MediaSubtype subtype) {
    if (mediaType.sub == subtype) {
      return this;
    }
    final mimeParts = parts;
    if (mimeParts != null) {
      for (final mimePart in mimeParts) {
        final match = mimePart.getPartWithMediaSubtype(subtype);
        if (match != null) {
          return match;
        }
      }
    }
    return null;
  }

  /// Searches for this the given subtype as a part of a `Multipart/Alternative` mime part.
  ///
  /// This is useful if you want to check for your preferred rendering format present as an alternative.
  MimePart? getAlternativePart(MediaSubtype subtype) {
    if (mediaType.sub == MediaSubtype.multipartAlternative) {
      return getPartWithMediaSubtype(subtype);
    }
    final mimeParts = parts;
    if (mimeParts != null) {
      for (final mimePart in mimeParts) {
        final match = mimePart.getAlternativePart(subtype);
        if (match != null) {
          return match;
        }
      }
    }
    return null;
  }

  /// Tries to find a 'content-type: text/plain' part and decodes its contents when found.
  String? decodeTextPlainPart() {
    return _decodeTextPart(this, MediaSubtype.textPlain);
  }

  /// Tries to find a 'content-type: text/html' part and decodes its contents when found.
  String? decodeTextHtmlPart() {
    return _decodeTextPart(this, MediaSubtype.textHtml);
  }

  static String? _decodeTextPart(MimePart part, MediaSubtype subtype) {
    if (!part._isParsed) {
      part.parse();
    }
    final mediaType = part.mediaType;
    if (mediaType.sub == subtype) {
      return part.decodeContentText();
    }
    if (part.parts != null) {
      for (final childPart in part.parts!) {
        final decoded = _decodeTextPart(childPart, subtype);
        if (decoded != null) {
          return decoded;
        }
      }
    }
    return null;
  }

  /// Parses this and all children MIME parts.
  void parse() {
    _isParsed = true;
    if (mimeData != null) {
      mimeData!.parse(null);
      if (mimeData!.containsHeader) {
        headers = mimeData!.headersList;
      }
      if (mimeData!.hasParts) {
        parts = [];
        for (final dataPart in mimeData!.parts!) {
          final part = MimePart()
            ..mimeData = dataPart
            ..headers = dataPart.headersList;
          parts!.add(part);
          part.parse();
        }
      }
    } else if (parts != null) {
      for (final part in parts!) {
        part.parse();
      }
    }
  }

  /// Renders this mime part with all children parts into the specified [buffer].
  ///
  /// You can set [renderHeader] to `false` when the message headers should not be rendered.
  void render(StringBuffer buffer, {bool renderHeader = true}) {
    if (mimeData != null) {
      if (!mimeData!.containsHeader && renderHeader) {
        _renderHeaders(buffer);
        buffer.write('\r\n');
      }
      mimeData!.render(buffer);
    } else {
      if (renderHeader) {
        _renderHeaders(buffer);
        buffer.write('\r\n');
      }
      if (parts?.isNotEmpty ?? false) {
        final multiPartBoundary = getHeaderContentType()?.boundary;
        if (multiPartBoundary == null) {
          throw StateError(
              'mime message rendering error: parts present but no multiPartBoundary defined.');
        }
        for (final part in parts!) {
          buffer.write('--');
          buffer.write(multiPartBoundary);
          buffer.write('\r\n');
          part.render(buffer);
          buffer.write('\r\n');
        }
        buffer.write('--');
        buffer.write(multiPartBoundary);
        buffer.write('--');
        buffer.write('\r\n');
      }
    }
  }

  void _renderHeaders(StringBuffer buffer) {
    if (headers != null) {
      for (final header in headers!) {
        header.render(buffer);
      }
    }
  }
}

/// A MIME message
class MimeMessage extends MimePart {
  /// The index of the message, if known
  int? sequenceId;

  /// The uid of the message, if known
  int? uid;

  /// The modifications sequence of this message.
  /// This is only returned by servers that support the CONDSTORE capability and can be fetch explicitely with 'MODSEQ'.
  int? modSequence;

  /// Message flags like \Seen, \Recent, etc
  List<String>? flags;

  /// The internal date of the message on the recipient's provider server
  String? internalDate;

  /// The size of the message in bytes
  int? size;

  /// The thread sequence, this can be populated manually or with [MailClient.fetchThreadData].
  MessageSequence? threadSequence;

  /// Checks if this message has been read
  bool get isSeen => hasFlag(MessageFlags.seen);

  /// Sets the `\Seen` flag for this message
  set isSeen(bool value) => setFlag(MessageFlags.seen, value);

  /// Checks if this message has been replied
  bool get isAnswered => hasFlag(MessageFlags.answered);

  /// Sets the `\Answered` flag for this message
  set isAnswered(bool value) => setFlag(MessageFlags.answered, value);

  /// Checks if this message has been forwarded
  bool get isForwarded => hasFlag(MessageFlags.keywordForwarded);

  /// Sets the `$Forwarded` keyword flag for this message
  set isForwarded(bool value) => setFlag(MessageFlags.keywordForwarded, value);

  /// Checks if this message has been marked as important / flagged
  bool get isFlagged => hasFlag(MessageFlags.flagged);

  /// Sets the `\Flagged` flag for this message
  set isFlagged(bool value) => setFlag(MessageFlags.flagged, value);

  /// Checks if this message has been marked as deleted
  bool get isDeleted => hasFlag(MessageFlags.deleted);

  /// Sets the `\Deleted` flag for this message
  set isDeleted(bool value) => setFlag(MessageFlags.deleted, value);

  /// Checks if a read receipt has been sent for this message
  @Deprecated('Use isReadReceiptSent instead')
  bool get isMdnSent => hasFlag(MessageFlags.keywordMdnSent);

  /// Sets the `$MDNSent` keyword flag for this message
  @Deprecated('Use isReadReceiptSent instead')
  set isMdnSent(bool value) => setFlag(MessageFlags.keywordMdnSent, value);

  /// Checks if a read receipt has been sent for this message
  ///
  /// Compare [isReadReceiptRequested]
  bool get isReadReceiptSent => hasFlag(MessageFlags.keywordMdnSent);

  /// Sets if a read receipt has been sent for this message
  ///
  /// Compare [isReadReceiptRequested]
  set isReadReceiptSent(bool value) =>
      setFlag(MessageFlags.keywordMdnSent, value);

  /// Checks if a disposition notification message is requested.
  ///
  /// This getter checks if there is already a [MessageFlags.keywordMdnSent] flag, if that's the case, `false` is returned.
  /// Then it is checked if either the [MailConventions.headerDispositionNotificationTo] or a `Return-Receipt-To` header is present.
  /// Compare [isReadReceiptSent]
  bool get isReadReceiptRequested {
    final mimeHeaders = headers;
    return !isReadReceiptSent &&
        (mimeHeaders != null &&
            mimeHeaders.any((h) =>
                h.lowerCaseName == 'disposition-notification-to' ||
                h.lowerCaseName == 'return-receipt-to'));
  }

  /// Checks if this message contents has been downloaded
  bool get isDownloaded =>
      ((mimeData != null) || (_individualParts?.isNotEmpty ?? false));

  /// The email of the first from address of this message
  String? get fromEmail {
    if (from != null && from!.isNotEmpty) {
      return from!.first.email;
    } else if (headers != null) {
      final fromHeaderValue =
          headers!.firstWhereOrNull((h) => h.lowerCaseName == 'from')?.value;
      if (fromHeaderValue != null) {
        return ParserHelper.parseEmail(fromHeaderValue);
      }
    }
    return null;
  }

  List<MailAddress>? _from;

  /// according to RFC 2822 section 3.6.2. there can be more than one FROM address, in that case the sender MUST be specified
  List<MailAddress>? get from => _getFromAddresses();
  set from(List<MailAddress>? list) => _from = list;
  MailAddress? _sender;
  MailAddress? get sender => _getSenderAddress();
  set sender(MailAddress? address) => _sender = address;
  List<MailAddress>? _replyTo;
  List<MailAddress>? get replyTo => _getReplyToAddresses();
  set replyTo(List<MailAddress>? list) => _replyTo = list;
  List<MailAddress>? _to;
  List<MailAddress>? get to => _getToAddresses();
  set to(List<MailAddress>? list) => _to = list;
  List<MailAddress>? _cc;
  List<MailAddress>? get cc => _getCcAddresses();
  set cc(List<MailAddress>? list) => _cc = list;
  List<MailAddress>? _bcc;
  List<MailAddress>? get bcc => _getBccAddresses();
  set bcc(List<MailAddress>? list) => _bcc = list;
  Map<String, MimePart>? _individualParts;

  /// The body structure of the message.
  ///
  /// This field is only populated when fetching either `BODY`, `BODYSTRUCTURE` elements.
  BodyPart? body;

  Envelope? _envelope;

  /// The envelope of the message.
  ///
  /// This field is only populated when fetching `ENVELOPE`.
  Envelope? get envelope => _envelope;
  set envelope(Envelope? value) {
    _envelope = value;
    if (value != null) {
      from = value.from;
      to = value.to;
      cc = value.cc;
      bcc = value.bcc;
      replyTo = value.replyTo;
      sender = value.sender;
    }
  }

  /// Retrieves the mail addresses of all message recipients
  List<String> get recipientAddresses =>
      recipients.map((r) => r.email).toList();

  /// Retrieves the mail addresses of all message recipients
  List<MailAddress> get recipients {
    final recipients = <MailAddress>[];
    final t = to;
    if (t != null) {
      recipients.addAll(t);
    }
    final c = cc;
    if (c != null) {
      recipients.addAll(c);
    }
    final b = bcc;
    if (b != null) {
      recipients.addAll(b);
    }
    return recipients;
  }

  String? _decodedSubject;

  /// Decodes the subject of this message
  String? decodeSubject() {
    _decodedSubject ??= decodeHeaderValue('subject');
    return _decodedSubject;
  }

  /// Renders the complete message into a String.
  ///
  /// Optionally exclude the rendering of the headers by setting [renderHeader] to `false`
  /// Internally calls [render] to render all mime parts.
  String renderMessage({bool renderHeader = true}) {
    final buffer = StringBuffer();
    render(buffer, renderHeader: renderHeader);
    return buffer.toString();
  }

  /// Creates a new message based on the specified rendered text form.
  ///
  /// Compare [renderMessage] method for converting a message to text.
  static MimeMessage parseFromText(String text) {
    final message = MimeMessage()..mimeData = TextMimeData(text, true);
    message.parse();
    return message;
  }

  /// Creates a new message based on the specified binary data.
  /// Compare [renderMessage] method for converting a message to text.
  static MimeMessage parseFromData(Uint8List data) {
    final message = MimeMessage()..mimeData = BinaryMimeData(data, true);
    message.parse();
    return message;
  }

  /// Checks if this is a typical text message
  /// Compare [isTextPlainMessage]
  /// Compare [decodeTextPlainPart]
  /// Compare [decodeTextHtmlPart]
  bool isTextMessage() {
    return mediaType.isText || (mediaType.isMultipart && hasTextPart(depth: 1));
  }

  /// Checks if this is a typical text message with a plain text part
  /// Compare [decodeTextPlainPart]
  /// Compare [isTextMessage]
  bool isTextPlainMessage() {
    return mediaType.sub == MediaSubtype.textPlain ||
        (mediaType.isMultipart && hasPart(MediaSubtype.textPlain, depth: 1));
  }

  /// Retrieves the sender of the this message by checking the `reply-to`, `sender` and `from` header values in this order.
  /// Set [combine] to `true` in case you want to combine the addresses from these headers, by default the first non-emptry entry is returned.
  List<MailAddress> decodeSender({bool combine = false}) {
    var replyTo = decodeHeaderMailAddressValue('reply-to') ?? <MailAddress>[];
    if (combine || (replyTo.isEmpty)) {
      final senderValue =
          decodeHeaderMailAddressValue('sender') ?? <MailAddress>[];
      if (combine) {
        replyTo.addAll(senderValue);
      } else {
        replyTo = senderValue;
      }
    }
    if (combine || replyTo.isEmpty) {
      final fromValue = decodeHeaderMailAddressValue('from') ?? <MailAddress>[];
      if (combine) {
        replyTo.addAll(fromValue);
      } else {
        replyTo = fromValue;
      }
    }
    return replyTo;
  }

  /// Checks of this messagin is from the specified [sender] address.
  /// Optionally specify known [aliases] and set [allowPlusAliases] to `true` to allow aliass such as `me+alias@domain.com`.
  /// Set [allowPlusAliases] to `true` in case + aliases like `me+alias@domain.com` are valid.
  bool isFrom(MailAddress sender,
      {List<MailAddress>? aliases, bool allowPlusAliases = false}) {
    return (findSender(sender,
            aliases: aliases, allowPlusAliases: allowPlusAliases) !=
        null);
  }

  /// Finds the matching [sender] address.
  /// Optionally specify known [aliases] and set [allowPlusAliases] to `true` to allow aliass such as `me+alias@domain.com`.
  MailAddress? findSender(MailAddress sender,
      {List<MailAddress>? aliases, bool allowPlusAliases = false}) {
    final searchFor = [sender];
    if (aliases != null) {
      searchFor.addAll(aliases);
    }
    final searchIn = decodeSender(combine: true);
    return MailAddress.getMatch(searchFor, searchIn,
        handlePlusAliases: allowPlusAliases);
  }

  /// Finds the matching [recipient] address.
  /// Optionally specify known [aliases] and set [allowPlusAliases] to `true` to allow aliass such as `me+alias@domain.com`.
  MailAddress? findRecipient(MailAddress recipient,
      {List<MailAddress>? aliases, bool allowPlusAliases = false}) {
    final searchFor = [recipient];
    if (aliases != null) {
      searchFor.addAll(aliases);
    }
    final searchIn = <MailAddress>[];
    if (to != null) {
      searchIn.addAll(to!);
    }
    if (cc != null) {
      searchIn.addAll(cc!);
    }
    return MailAddress.getMatch(searchFor, searchIn,
        handlePlusAliases: allowPlusAliases);
  }

  /// Retrieves all content info of parts with the specified [disposition] `Content-Type`.
  /// By default the content info with `ContentDisposition.attachment` are retrieved.
  /// Typically this used to list all attachments of a message.
  /// Note that either the message contents (`BODY[]`) or the `BODYSTRUCTURE` is required to reliably list all matching content elements.
  /// All fetchId parsed from the `BODYSTRUCTURE` are returned in a form compatible
  /// with the body parts tree unless [withCleanParts] is false.
  List<ContentInfo> findContentInfo(
      {ContentDisposition disposition = ContentDisposition.attachment,
      bool? withCleanParts,
      bool? complete}) {
    withCleanParts ??= true;
    final result = <ContentInfo>[];
    if (body != null) {
      body!.collectContentInfo(disposition, result,
          withCleanParts: withCleanParts, complete: complete);
    } else if (parts?.isNotEmpty ?? false || body == null) {
      collectContentInfo(disposition, result, null, complete: complete);
    }
    return result;
  }

  /// Checks if this message has parts with the specified [disposition].
  /// Note that either the full message or the body structure must have been downloaded before.
  bool hasContent(ContentDisposition disposition) {
    return findContentInfo(disposition: disposition).isNotEmpty;
  }

  /// Checks if this message has parts with a `Content-Disposition: attachment` header.
  bool hasAttachments() {
    return hasContent(ContentDisposition.attachment);
  }

  /// Checks if this message contains either explicit attachments or non-textual inline parts.
  bool hasAttachmentsOrInlineNonTextualParts() {
    if (hasAttachments()) {
      return true;
    } else {
      final inlineParts =
          findContentInfo(disposition: ContentDisposition.inline);
      for (final info in inlineParts) {
        if (!info.isText) {
          return true;
        }
      }
    }
    return false;
  }

  /// Checks if this message any inline parts.
  bool hasInlineParts() {
    final inlineParts = findContentInfo(disposition: ContentDisposition.inline);
    return inlineParts.isNotEmpty;
  }

  /// Retrieves the part with the specified [fetchId].
  ///
  /// Returns null if the part has not been loaded (yet).
  MimePart? getPart(String fetchId) {
    if (fetchId.isEmpty) {
      throw StateError(
          'Invalid empty fetchId in MimeMessage.getPart(fetchId).');
    }
    final partsByFetchId = _individualParts;
    if (partsByFetchId != null) {
      final part = partsByFetchId[fetchId];
      if (part != null) {
        return part;
      }
    }
    final idParts = fetchId.split('.').map<int?>((part) => int.tryParse(part));
    MimePart parent = this;
    var warningGiven = false;
    for (final id in idParts) {
      if (id == null) {
        if (!warningGiven) {
          print(
              'Warning: unable to retrieve individual parts from fetchId [$fetchId] (in MimeMessage.getPart(fetchId)).');
          warningGiven = true;
        }
        continue;
      }
      final parts = parent.parts;
      if (parts == null || parts.length < id) {
        // this mime message is not fully loaded
        return null;
      }
      parent = parts[id - 1];
    }
    return parent;
  }

  @override
  MimePart? getPartWithMediaSubtype(MediaSubtype subtype) {
    var match = super.getPartWithMediaSubtype(subtype);
    if (match == null) {
      final partsByFetchId = _individualParts;
      if (partsByFetchId != null) {
        match = partsByFetchId.values
            .firstWhereOrNull((p) => p.mediaType.sub == subtype);
      }
    }
    return match;
  }

  @override
  MimePart? getAlternativePart(MediaSubtype subtype) {
    final match = super.getAlternativePart(subtype);
    if (match == null) {
      if (mediaType.sub == subtype) {
        return this;
      }
      final partsByFetchId = _individualParts;
      final structure = body;
      if (partsByFetchId != null && structure != null) {
        final alternativeBodyPart =
            structure.findFirst(MediaSubtype.multipartAlternative);
        if (alternativeBodyPart != null) {
          final matchBodyPart = alternativeBodyPart.findFirst(subtype);
          if (matchBodyPart != null) {
            return partsByFetchId[matchBodyPart.fetchId];
          }
        }
      }
    }
    return match;
  }

  /// Sets the individually loaded [part] with the given [fetchId].
  ///
  /// call [getPart(fetchId)] to retrieve a part.
  void setPart(String fetchId, MimePart part) {
    _individualParts ??= <String, MimePart>{};
    final existing = body?.getChildPart(fetchId);
    if (existing != null) {
      part._contentTypeHeader = existing.contentType;
      part._contentDispositionHeader = existing.contentDisposition;
      part.addHeader(
          MailConventions.headerContentTransferEncoding, existing.encoding);
    }
    _individualParts![fetchId] = part;
  }

  /// Puts all parts of this message into a flat sequential list.
  List<MimePart> get allPartsFlat {
    final allParts = <MimePart>[];
    if (_individualParts != null) {
      allParts.addAll(_individualParts!.values);
    }
    _addPartsFlat(this, allParts);
    return allParts;
  }

  void _addPartsFlat(MimePart part, List<MimePart> allParts) {
    allParts.add(part);
    if (part.parts != null) {
      for (final child in part.parts!) {
        _addPartsFlat(child, allParts);
      }
    }
  }

  /// Retrieves the part with the specified Content-ID [cid].
  MimePart? getPartWithContentId(String cid) {
    if (!cid.startsWith('<')) {
      cid = '<$cid>';
    }
    cid = cid.toLowerCase();
    final allParts = allPartsFlat;
    for (final part in allParts) {
      final partCid = part._getLowerCaseHeaderValue('content-id');
      if (partCid != null && partCid.toLowerCase() == cid) {
        return part;
      }
    }
    if (body != null) {
      final bodyPart = body!.findFirstWithContentId(cid);
      if (bodyPart != null) {
        return getPart(bodyPart.fetchId!);
      }
    }
    return null;
  }

  void copyIndividualParts(MimeMessage other) {
    if (other._individualParts != null) {
      for (final key in other._individualParts!.keys) {
        setPart(key, other._individualParts![key]!);
      }
    }
  }

  List<MailAddress>? _getFromAddresses() {
    var addresses = _from;
    if (addresses == null) {
      addresses = decodeHeaderMailAddressValue('from');
      _from = addresses;
    }
    return addresses;
  }

  List<MailAddress>? _getReplyToAddresses() {
    var addresses = _replyTo;
    if (addresses == null) {
      addresses = decodeHeaderMailAddressValue('reply-to');
      _replyTo = addresses;
    }
    return addresses;
  }

  List<MailAddress>? _getToAddresses() {
    var addresses = _to;
    if (addresses == null) {
      addresses = decodeHeaderMailAddressValue('to');
      _to = addresses;
    }
    return addresses;
  }

  List<MailAddress>? _getCcAddresses() {
    var addresses = _cc;
    if (addresses == null) {
      addresses = decodeHeaderMailAddressValue('cc');
      _cc = addresses;
    }
    return addresses;
  }

  List<MailAddress>? _getBccAddresses() {
    var addresses = _bcc;
    if (addresses == null) {
      addresses = decodeHeaderMailAddressValue('bcc');
      _bcc = addresses;
    }
    return addresses;
  }

  MailAddress? _getSenderAddress() {
    var address = _sender;
    if (address == null) {
      final addresses = decodeHeaderMailAddressValue('sender');
      if (addresses?.isNotEmpty ?? false) {
        address = addresses!.first;
      }
      _sender = address;
    }
    return address;
  }

  @override
  String toString() {
    return renderMessage();
  }

  /// Checks if the messages has the message flag with the specified [name].
  bool hasFlag(String name) {
    final mimeFlags = flags;
    return (mimeFlags != null) && mimeFlags.contains(name);
  }

  /// Adds the flag with the specified [name] to this message.
  ///
  /// Note that this only affects this message instance and is not persisted or
  /// reported to the mail service automatically.
  void addFlag(String name) {
    final mimeFlags = flags;
    if (mimeFlags == null) {
      flags = [name];
    } else if (!mimeFlags.contains(name)) {
      mimeFlags.add(name);
    }
  }

  /// Removes the flag with the specified [name] from this message.
  ///
  /// Note that this only affects this message instance and is not persisted or
  /// reported to the mail service automatically.
  void removeFlag(String name) {
    if (flags == null) {
      flags = [];
    } else {
      flags!.remove(name);
    }
  }

  /// Adds or removes the flag with the specified [name] to/from this message depending on [value].
  ///
  /// Note that this only affects this message instance and is not persisted or
  /// reported to the mail service automatically.
  void setFlag(String name, bool enable) {
    if (enable == true) {
      addFlag(name);
    } else {
      removeFlag(name);
    }
  }

  @override
  String? decodeTextPlainPart() {
    final decoded = super.decodeTextPlainPart();
    if (decoded == null) {
      return _decodeTextPartFromBody(MediaSubtype.textPlain);
    }
    return decoded;
  }

  @override
  String? decodeTextHtmlPart() {
    final decoded = super.decodeTextHtmlPart();
    if (decoded == null) {
      return _decodeTextPartFromBody(MediaSubtype.textHtml);
    }
    return decoded;
  }

  @override
  ContentTypeHeader? getHeaderContentType() {
    var header = super.getHeaderContentType();
    header ??= body?.contentType;
    return header;
  }

  String? _decodeTextPartFromBody(MediaSubtype subtype) {
    if (body != null) {
      final bodyPart = body!.findFirst(subtype);
      if (bodyPart != null) {
        final part = getPart(bodyPart.fetchId!);
        if (part != null) {
          if (!part._isParsed) {
            part.parse();
          }
          if (part.mimeData != null) {
            return part.mimeData!.decodeText(
              bodyPart.contentType,
              bodyPart.encoding,
            );
          }
        }
      }
    }
    return null;
  }
}

/// Encapsulates a MIME header
class Header {
  final String name;
  final String? value;
  final HeaderEncoding encoding;
  String? lowerCaseName;

  Header(this.name, this.value, [this.encoding = HeaderEncoding.none]) {
    lowerCaseName = name.toLowerCase();
  }

  @override
  String toString() {
    return '$name: $value';
  }

  void toStringBuffer(StringBuffer buffer) {
    buffer.write(name);
    buffer.write(': ');
    buffer.write(value);
  }

  void render(StringBuffer buffer) {
    var length =
        name.length + ': '.length + (value == null ? 0 : value!.length);
    buffer.write(name);
    buffer.write(': ');
    if (length < MailConventions.textLineMaxLength) {
      if (value != null) {
        buffer.write(value);
      }
      buffer.write('\r\n');
    } else {
      var currentLineLength = name.length + ': '.length;
      length -= name.length + ': '.length;
      final runes = value!.runes.toList();
      var startIndex = 0;
      while (length > 0) {
        var chunkLength = MailConventions.textLineMaxLength - currentLineLength;
        if (startIndex + chunkLength >= value!.length) {
          // write reminder:
          buffer.write(value!.substring(startIndex).trim());
          buffer.write('\r\n');
          break;
        }
        for (var runeIndex = startIndex + chunkLength;
            runeIndex > startIndex;
            runeIndex--) {
          final rune = runes[runeIndex];
          if (rune == AsciiRunes.runeSemicolon ||
              rune == AsciiRunes.runeSpace ||
              rune == AsciiRunes.runeClosingParentheses ||
              rune == AsciiRunes.runeClosingBracket ||
              rune == AsciiRunes.runeGreaterThan) {
            chunkLength = runeIndex - startIndex + 1;
            break;
          }
        }
        buffer.write(
            value!.substring(startIndex, startIndex + chunkLength).trim());
        buffer.write('\r\n');
        length -= chunkLength;
        startIndex += chunkLength;
        if (length > 0) {
          buffer.writeCharCode(AsciiRunes.runeTab);
          currentLineLength = 1;
        }
      }
    }
  }
}

/// A BODY or BODYSTRUCTURE information element
class BodyPart {
  /// Children parts, if present
  List<BodyPart>? parts;

  /// A string giving the content id as defined in [MIME-IMB].
  String? cid;

  /// A string giving the content description as defined in [MIME-IMB].
  String? description;

  /// A string giving the content transfer encoding as defined in [MIME-IMB].
  /// Examples: base64, quoted-printable
  String? encoding;

  /// A number giving the size of the body in octets.
  /// Note that this size is the size in its transfer encoding and not the
  ///   resulting size after any decoding.
  int? size;

  /// Some message types like MESSAGE/RFC822 or TEXT also provide the number of lines
  int? numberOfLines;

  /// The content type infomation.
  ContentTypeHeader? contentType;

  /// The content disposition information. This is constructed when querying BODYSTRUCTURE in a fetch.
  ContentDispositionHeader? contentDisposition;

  /// The raw text of this body part. This is set when fetching the message contents e.g. with `BODY[]`.
  String? bodyRaw;

  /// The envelope, only provided for message/rfc822 structures
  Envelope? envelope;

  /// The ID for fetching this body part, e.g. `1.2` for a part that can then be fetched with the criteria `BODY[1.2]`.
  String? _fetchId;
  String? get fetchId {
    _fetchId ??= _getFetchId();
    return _fetchId;
  }

  BodyPart? _parent;

  BodyPart addPart([BodyPart? childPart]) {
    childPart ??= BodyPart();
    parts ??= <BodyPart>[];
    parts!.add(childPart);
    childPart._parent = this;
    return childPart;
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    write(buffer);
    return buffer.toString();
  }

  void write(StringBuffer buffer, [String padding = '']) {
    buffer
      ..write(padding)
      ..write('[')
      ..write(fetchId)
      ..write(']\n');
    if (contentType != null) {
      buffer.write(padding);
      contentType!.render(buffer);
      buffer.write('\n');
    }
    if (contentDisposition != null) {
      buffer.write(padding);
      contentDisposition!.render(buffer);
      buffer.write('\n');
    }
    if (parts != null && parts!.isNotEmpty) {
      buffer.write(padding);
      buffer.write('[\n');
      var addComma = false;
      for (final part in parts!) {
        if (addComma) {
          buffer.write(padding);
          buffer.write(',\n');
        }
        part.write(buffer, padding + ' ');
        addComma = true;
      }
      buffer.write(padding);
      buffer.write(']\n');
    }
  }

  String? _getFetchId([String? tail]) {
    final parent = _parent;
    if (parent != null) {
      final index = parent.parts!.indexOf(this);
      var fetchIdPart = (index + 1).toString();
      // Rationale: if this part is a direct child of a message/rfc822 part and
      // is also a multipart, the numeric fetchId will be overwitten with 'TEXT'
      if (_parent!.contentType?.mediaType.sub == MediaSubtype.messageRfc822) {
        if (contentType?.mediaType.top == MediaToptype.multipart) {
          fetchIdPart = 'TEXT';
        }
      }
      if (tail == null) {
        tail = fetchIdPart;
      } else {
        tail = fetchIdPart + '.' + tail;
      }
      return parent._getFetchId(tail);
    } else {
      return tail;
    }
  }

  /// Adds the matching disposition header with the specified [disposition] of this part and this children parts to the [result].
  /// Optionally set [reverse] to `true` to add all parts that do not match the specified `disposition`.
  /// All fetchId parsed from the `BODYSTRUCTURE` are returned in a form compatible
  /// with the body parts tree unless [withCleanParts] is false.
  /// Set [complete] to `false` to skip the included rfc822 messages parts.
  void collectContentInfo(
      ContentDisposition disposition, List<ContentInfo> result,
      {bool? reverse, bool? withCleanParts, bool? complete}) {
    reverse ??= false;
    withCleanParts ??= true;
    complete ??= true;
    final isMessage = contentType?.mediaType.isMessage ?? false;
    if (fetchId != null) {
      if ((!reverse && contentDisposition?.disposition == disposition) ||
          (reverse &&
              contentDisposition?.disposition != disposition &&
              contentType?.mediaType.top != MediaToptype.multipart)) {
        if (!withCleanParts ||
            (withCleanParts && !fetchId!.endsWith('.TEXT'))) {
          final info = ContentInfo(
              withCleanParts ? fetchId!.replaceAll('.TEXT', '') : fetchId!)
            ..contentDisposition = contentDisposition
            ..contentType = contentType
            ..cid = cid;
          result.add(info);
        }
      }
    }
    if (!complete &&
        isMessage &&
        ((reverse && disposition == ContentDisposition.attachment) ||
            (!reverse && disposition == ContentDisposition.inline))) {
      // abort to search for inline parts at messages, unless attachments are searched
      return;
    }
    if (parts?.isNotEmpty ?? false) {
      for (final part in parts!) {
        if ((disposition == ContentDisposition.attachment &&
                reverse &&
                part.contentDisposition?.disposition ==
                    ContentDisposition.attachment) ||
            (disposition == ContentDisposition.inline &&
                !reverse &&
                part.contentDisposition?.disposition ==
                    ContentDisposition.attachment)) {
          // abort at attachents when inline parts are searched for
          continue;
        }
        part.collectContentInfo(disposition, result,
            reverse: reverse,
            withCleanParts: withCleanParts,
            complete: complete);
      }
    }
  }

  BodyPart? findFirst(MediaSubtype subtype) {
    if (contentType?.mediaType.sub == subtype) {
      return this;
    }
    if (parts?.isNotEmpty ?? false) {
      for (final part in parts!) {
        final first = part.findFirst(subtype);
        if (first != null) {
          return first;
        }
      }
    }
    return null;
  }

  BodyPart? getChildPart(String partFetchId) {
    final _fetchId = partFetchId.contains('.TEXT')
        ? fetchId
        : fetchId?.replaceAll('.TEXT', '');
    // Handle the searching for the .HEADER part of a nested rfc822 part
    if (_fetchId == partFetchId ||
        _fetchId == partFetchId.replaceFirst('.HEADER', '')) {
      return this;
    }
    if (parts != null) {
      for (final part in parts!) {
        final match = part.getChildPart(partFetchId);
        if (match != null) {
          return match;
        }
      }
    }
    return null;
  }

  BodyPart? findFirstWithContentId(String partCid) {
    if (cid == partCid) {
      return this;
    }
    if (parts != null) {
      for (final part in parts!) {
        final match = part.findFirstWithContentId(partCid);
        if (match != null) {
          return match;
        }
      }
    }
    return null;
  }

  /// Retrieves the number of nested parts
  int get length => parts?.length ?? 0;

  /// Eases access to a nested part, same as accessing `parts[index]`
  BodyPart operator [](int index) => parts != null
      ? parts!.elementAt(index)
      : throw RangeError('$index invalid for BodyPart with length of 0');

  /// Retrieves all leaf parts, ie all parts that have no children parts themselves.
  ///
  /// This can be useful to check all content parts of the message
  List<BodyPart> get allLeafParts {
    final leafParts = <BodyPart>[];
    _addLeafParts(leafParts);
    return leafParts;
  }

  void _addLeafParts(List<BodyPart> leafParts) {
    final myParts = parts;
    if (myParts == null) {
      leafParts.add(this);
      return;
    }
    for (final part in myParts) {
      part._addLeafParts(leafParts);
    }
  }
}

class Envelope {
  DateTime? date;
  String? subject;
  List<MailAddress>? from;
  MailAddress? sender;
  List<MailAddress>? replyTo;
  List<MailAddress>? to;
  List<MailAddress>? cc;
  List<MailAddress>? bcc;
  String? inReplyTo;
  String? messageId;
}

class ParameterizedHeader {
  /// The raw value of the header
  String rawValue;

  /// The value without parameters as specified in the header, eg 'text/plain' for a Content-Type header.
  late String value;

  /// Any parameters, for example charset, boundary, filename, etc
  final parameters = <String, String>{};

  ParameterizedHeader(this.rawValue) {
    final elements = rawValue.split(';');
    value = elements[0];
    for (var i = 1; i < elements.length; i++) {
      final element = elements[i].trim();
      final splitPos = element.indexOf('=');
      if (splitPos == -1) {
        parameters[element.toLowerCase()] = '';
      } else {
        final name = element.substring(0, splitPos).toLowerCase();
        final value = element.substring(splitPos + 1);
        final valueWithoutQuotes = removeQuotes(value);
        parameters[name] = valueWithoutQuotes;
      }
    }
  }

  String removeQuotes(String value) {
    if (value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  void renderField(
      String name, String? value, bool quote, StringBuffer buffer) {
    if (value == null) {
      return;
    }
    buffer.write('; ');
    buffer.write(name);
    buffer.write('=');
    if (quote) {
      buffer.write('"');
    }
    buffer.write(value);
    if (quote) {
      buffer.write('"');
    }
  }

  void renderDateField(String name, DateTime? date, StringBuffer buffer) {
    if (date == null) {
      return;
    }
    renderField(name, DateCodec.encodeDate(date), true, buffer);
  }

  void renderRemainingFields(StringBuffer buffer, {List<String>? exclude}) {
    for (final key in parameters.keys) {
      if (exclude == null || !exclude.contains(key.toLowerCase())) {
        renderField(key, parameters[key], false, buffer);
      }
    }
  }

  /// Adds a new or replaces and existing parameter [name] with the value [quotedValue].
  void setParameter(String name, String quotedValue) {
    parameters[name] = quotedValue;
  }
}

/// Eases reading content-type header values
class ContentTypeHeader extends ParameterizedHeader {
  late MediaType mediaType;

  /// the used charset like 'utf-8', this is always converted to lowercase if present
  String? charset;

  /// the boundary for content-type headers with a 'multipart' [topLevelTypeText].
  String? boundary;

  /// defines wether the 'text/plain' content-header has a 'flowed=true' or semantically equivalent value.
  bool? isFlowedFormat;

  ContentTypeHeader(String rawValue) : super(rawValue) {
    mediaType = MediaType.fromText(value);
    charset = parameters['charset']?.toLowerCase();
    boundary = parameters['boundary'];
    if (parameters.containsKey('format')) {
      isFlowedFormat = parameters['format']!.toLowerCase() == 'flowed';
    }
  }

  String render([StringBuffer? buffer]) {
    buffer ??= StringBuffer();
    buffer.write(value);
    renderField('charset', charset, true, buffer);
    renderField('boundary', boundary, true, buffer);
    if (isFlowedFormat == true) {
      renderField('format', 'flowed', false, buffer);
    }
    renderRemainingFields(buffer, exclude: ['charset', 'boundary', 'format']);
    return buffer.toString();
  }

  @override
  void setParameter(String name, String quotedValue) {
    name = name.toLowerCase();
    if (name == 'charset') {
      quotedValue = removeQuotes(quotedValue).toLowerCase();
      charset = quotedValue;
    } else if (name == 'boundary') {
      quotedValue = removeQuotes(quotedValue);
      boundary = quotedValue;
    } else if (name == 'format') {
      quotedValue = removeQuotes(quotedValue).toLowerCase();
      isFlowedFormat = (quotedValue == 'flowed');
    }
    super.setParameter(name, quotedValue);
  }

  static ContentTypeHeader from(MediaType mediaType,
      {String? charset, String? boundary, bool? isFlowedFormat}) {
    final type = ContentTypeHeader(mediaType.text);
    type.charset = charset;
    type.boundary = boundary;
    type.isFlowedFormat = isFlowedFormat;
    return type;
  }
}

/// Specifies the content disposition of a mime part.
/// Compare https://tools.ietf.org/html/rfc2183 for details.
enum ContentDisposition { inline, attachment, other }

/// Specifies the content disposition header of a mime part.
/// Compare https://tools.ietf.org/html/rfc2183 for details.
class ContentDispositionHeader extends ParameterizedHeader {
  late String dispositionText;
  late ContentDisposition disposition;
  String? filename;
  DateTime? creationDate;
  DateTime? modificationDate;
  DateTime? readDate;
  int? size;

  ContentDispositionHeader(String rawValue) : super(rawValue) {
    dispositionText = value;
    switch (dispositionText.toLowerCase()) {
      case 'inline':
        disposition = ContentDisposition.inline;
        break;
      case 'attachment':
        disposition = ContentDisposition.attachment;
        break;
      default:
        disposition = ContentDisposition.other;
        break;
    }

    filename = MailCodec.decodeHeader(parameters['filename']);
    creationDate = DateCodec.decodeDate(parameters['creation-date']);
    modificationDate = DateCodec.decodeDate(parameters['modification-date']);
    readDate = DateCodec.decodeDate(parameters['read-date']);
    final sizeText = parameters['size'];
    if (sizeText != null) {
      size = int.tryParse(sizeText);
    }
  }

  /// Convenuience method to create a `Content-Disposition: inline` header
  static ContentDispositionHeader inline(
          {String? filename,
          DateTime? creationDate,
          DateTime? modificationDate,
          DateTime? readDate,
          int? size}) =>
      from(ContentDisposition.inline,
          filename: filename,
          creationDate: creationDate,
          modificationDate: modificationDate,
          readDate: readDate,
          size: size);

  /// Convenuience method to create a `Content-Disposition: attachment` header
  static ContentDispositionHeader attachment(
          {String? filename,
          DateTime? creationDate,
          DateTime? modificationDate,
          DateTime? readDate,
          int? size}) =>
      from(ContentDisposition.attachment,
          filename: filename,
          creationDate: creationDate,
          modificationDate: modificationDate,
          readDate: readDate,
          size: size);

  static ContentDispositionHeader from(ContentDisposition disposition,
      {String? filename,
      DateTime? creationDate,
      DateTime? modificationDate,
      DateTime? readDate,
      int? size}) {
    final rawValue;
    switch (disposition) {
      case ContentDisposition.inline:
        rawValue = 'inline';
        break;
      case ContentDisposition.attachment:
        rawValue = 'attachment';
        break;
      default:
        rawValue = 'unsupported';
        break;
    }
    final header = ContentDispositionHeader(rawValue);
    header.filename = filename;
    header.creationDate = creationDate;
    header.modificationDate = modificationDate;
    header.readDate = readDate;
    header.size = size;
    return header;
  }

  String render([StringBuffer? buffer]) {
    buffer ??= StringBuffer();
    buffer.write(dispositionText);
    renderField('filename', filename, true, buffer);
    renderDateField('creation-date', creationDate, buffer);
    renderDateField('modification-date', modificationDate, buffer);
    renderDateField('read-date', readDate, buffer);
    if (size != null) {
      renderField('size', size.toString(), false, buffer);
    }
    renderRemainingFields(buffer, exclude: [
      'filename',
      'creation-date',
      'modification-date',
      'read-date',
      'size'
    ]);
    return buffer.toString();
  }

  @override
  void setParameter(String name, String quotedValue) {
    name = name.toLowerCase();
    if (name == 'filename') {
      quotedValue = removeQuotes(quotedValue);
      filename = quotedValue;
    } else if (name == 'creation-date') {
      quotedValue = removeQuotes(quotedValue);
      creationDate = DateCodec.decodeDate(quotedValue);
    } else if (name == 'modification-date') {
      quotedValue = removeQuotes(quotedValue);
      modificationDate = DateCodec.decodeDate(quotedValue);
    } else if (name == 'read-date') {
      quotedValue = removeQuotes(quotedValue);
      readDate = DateCodec.decodeDate(quotedValue);
    } else if (name == 'size') {
      size = int.tryParse(quotedValue);
    }
    super.setParameter(name, quotedValue);
  }
}

/// Provides high level information about content parts.
///
/// Compare `MimeMessage.listContentInfo()`.
class ContentInfo {
  ContentDispositionHeader? contentDisposition;
  ContentTypeHeader? contentType;
  final String fetchId;
  String? cid;
  String? _decodedFileName;
  String? get fileName {
    _decodedFileName ??= MailCodec.decodeHeader(
        (contentDisposition?.filename ?? contentType?.parameters['name']));
    return _decodedFileName;
  }

  ContentInfo(this.fetchId);

  int? get size => contentDisposition?.size;
  MediaType? get mediaType => contentType?.mediaType;
  bool get isImage => mediaType?.top == MediaToptype.image;
  bool get isText => mediaType?.top == MediaToptype.text;
  bool get isModel => mediaType?.top == MediaToptype.model;
  bool get isAudio => mediaType?.top == MediaToptype.audio;
  bool get isApplication => mediaType?.top == MediaToptype.application;
  bool get isFont => mediaType?.top == MediaToptype.font;
  bool get isMessage => mediaType?.top == MediaToptype.message;
  bool get isVideo => mediaType?.top == MediaToptype.video;
  bool get isMultipart => mediaType?.top == MediaToptype.multipart;
  bool get isOther => mediaType?.top == MediaToptype.other;
}

/// Abstract a mime message thread
///
/// Compare [MailClient.fetchThreadedMessages] for fetching message threads.
class MimeThread {
  /// The full sequence for this thread
  final MessageSequence sequence;

  /// The IDs of the message sequence
  final List<int> ids;

  /// The length of this thread
  int get length => ids.length;

  /// The fetched messages of this thread
  final List<MimeMessage> messages;

  /// The latest message in this thread
  MimeMessage get latest => messages.last;

  /// Checks if this thread contains more messages than are already fetched
  bool get hasMoreMessages => length > messages.length;

  /// Retrieves the sequence for any messages that have not yet been loaded.
  ///
  /// Use [hasMoreMessages] to check  if there are indeed any messages missing.
  MessageSequence get missingMessageSequence {
    if (length == 0) {
      return sequence;
    }
    final isUid = sequence.isUidSequence;
    final missingIds = ids
        .where((id) => messages.any(
            (message) => isUid ? message.uid == id : message.sequenceId == id))
        .toList();
    final missing = MessageSequence.fromIds(missingIds, isUid: isUid);
    return missing;
  }

  /// Creates a new thread from the given [sequence] with the prefetched [messages].
  MimeThread(this.sequence, this.messages) : ids = sequence.toList() {
    assert(messages.isNotEmpty,
        'each thread requires at least one sequence entry, cehck sequence argument, which is empty');
    assert(sequence.isNotEmpty,
        'each thread requires at least one sequence entry, cehck sequence argument, which is empty');
  }
}
