require "test_helper"

class SessionInvalidationTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []
  test "changing password invalidates other active sessions" do
    user = User.create!(
      email: "person@example.com",
      password: "old_password",
      password_confirmation: "old_password"
    )

    session_a = open_session
    session_b = open_session

    sign_in(session_a, user, password: "old_password")
    sign_in(session_b, user, password: "old_password")

    old_session_token = user.session_token

    session_a.patch password_path, params: {
      user: {
        current_password: "old_password",
        password: "new_password",
        password_confirmation: "new_password"
      }
    }
    session_a.assert_redirected_to root_path
    session_a.follow_redirect!
    session_a.assert_response :success

    user.reload
    assert_not_equal old_session_token, user.session_token

    session_a.get root_path
    session_a.assert_response :success

    session_b.get root_path
    session_b.assert_redirected_to sign_in_path
  end

  test "sign in returns to the requested filtered page without replaying a mutation" do
    user = User.create!(email: "return-path@example.test", password: "test-password")
    get transactions_path(q: "Coffee", source: "manual")
    assert_redirected_to sign_in_path
    post sign_in_path, params: { email: user.email, password: "incorrect" }
    assert_response :unprocessable_entity
    post sign_in_path, params: { email: user.email, password: "test-password" }
    assert_redirected_to transactions_path(q: "Coffee", source: "manual")
    delete sign_out_path
    post transactions_path, params: { transaction: { name: "Must not replay", amount: 1 } }
    assert_redirected_to sign_in_path
    post sign_in_path, params: { email: user.email, password: "test-password" }
    assert_redirected_to root_path
    assert_equal 0, user.transactions.count
  end

  private

  def sign_in(session, user, password:)
    session.post sign_in_path, params: { email: user.email, password: password }
    session.assert_redirected_to root_path
    session.follow_redirect!
    session.assert_response :success
  end
end
