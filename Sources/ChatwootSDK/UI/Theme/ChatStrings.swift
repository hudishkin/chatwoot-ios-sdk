import Foundation

enum ChatStrings {
    private static func string(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    }

    static var chatTitle: String { string("chatwoot_chat_title") }
    static var composerHint: String { string("chatwoot_composer_hint") }
    static var send: String { string("chatwoot_send") }
    static var attach: String { string("chatwoot_attach") }
    static var attachPhoto: String { string("chatwoot_attach_photo") }
    static var attachFile: String { string("chatwoot_attach_file") }
    static var retry: String { string("chatwoot_retry") }
    static var failed: String { string("chatwoot_failed") }
    static var failedRetry: String { string("chatwoot_failed_retry") }
    static var messageDeleted: String { string("chatwoot_message_deleted") }
    static var empty: String { string("chatwoot_empty") }
    static var bannerConnecting: String { string("chatwoot_banner_connecting") }
    static var bannerOffline: String { string("chatwoot_banner_offline") }
    static var bannerLiveUnavailable: String { string("chatwoot_banner_live_unavailable") }
    static var today: String { string("chatwoot_date_today") }
    static var yesterday: String { string("chatwoot_date_yesterday") }
    static var copy: String { string("chatwoot_copy") }
    static var copied: String { string("chatwoot_copied") }
    static var open: String { string("chatwoot_cd_open") }
    static var imageRetry: String { string("chatwoot_image_retry") }
    static var attachTooLarge: String { string("chatwoot_attach_too_large") }
    static var attachFailed: String { string("chatwoot_attach_failed") }
    static var sendFailed: String { string("chatwoot_send_failed") }
    static var scrollToNewest: String { string("chatwoot_scroll_to_newest") }
    static var agentTyping: String { string("chatwoot_agent_typing") }
    static var you: String { string("chatwoot_cd_you") }
    static var agentUnnamed: String { string("chatwoot_cd_agent_unnamed") }
    static var sendingStatus: String { string("chatwoot_cd_sending") }
    static var sentStatus: String { string("chatwoot_cd_sent") }
    static var image: String { string("chatwoot_cd_image") }
    static var surveyCommentHint: String { string("chatwoot_survey_comment_hint") }
    static var surveyAddComment: String { string("chatwoot_survey_add_comment") }
    static var surveySend: String { string("chatwoot_survey_send") }
    static var surveyThanks: String { string("chatwoot_survey_thanks") }
    static var surveyClosed: String { string("chatwoot_survey_closed") }
    static var surveyFailed: String { string("chatwoot_survey_failed") }

    static func agent(_ name: String) -> String {
        String(format: string("chatwoot_cd_agent"), name)
    }

    static func file(_ name: String) -> String {
        String(format: string("chatwoot_cd_file"), name)
    }

    static func newMessages(_ count: Int) -> String {
        String(format: string("chatwoot_new_messages"), count)
    }

    static func surveyRate(_ value: Int, of max: Int) -> String {
        String(format: string("chatwoot_survey_rate"), value, max)
    }

    static func surveyRated(_ value: Int, of max: Int) -> String {
        String(format: string("chatwoot_survey_rated"), value, max)
    }
}
