package main

import "core:testing"
import "core:time"

@(test)
wake_result_expiry_test :: proc(t: ^testing.T) {
	wake: Wake_Control
	wake_set_result(&wake, .Success, .None)
	wake.result_visible_since = time.now()

	testing.expect(t, !wake_expire_result(&wake, time.time_add(wake.result_visible_since, time.Second)))
	testing.expect_value(t, wake_get_status(&wake), Wake_Status.Success)
	testing.expect(t, wake_expire_result(&wake, time.time_add(wake.result_visible_since, SWITCH_WAKE_RESULT_DURATION)))
	testing.expect_value(t, wake_get_status(&wake), Wake_Status.Idle)

	wake_set_result(&wake, .Failed, .Connect)
	wake.result_visible_since = time.now()
	testing.expect(t, wake_expire_result(&wake, time.time_add(wake.result_visible_since, SWITCH_WAKE_RESULT_DURATION)))
	testing.expect_value(t, wake_get_status(&wake), Wake_Status.Idle)
	testing.expect_value(t, wake_get_error(&wake), Wake_Error.None)
}
