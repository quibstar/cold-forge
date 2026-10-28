defmodule ColdForge.Inbox.MimeTest do
  use ExUnit.Case, async: true

  alias ColdForge.Inbox.Mime

  test "a plain message is its body" do
    raw =
      "From: a@b.test\r\nSubject: Hi\r\nMIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nSounds good.\r\n"

    assert Mime.text_body(raw) == "Sounds good."
  end

  test "quoted-printable is decoded" do
    raw =
      "From: a@b.test\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\n" <>
        "Content-Transfer-Encoding: quoted-printable\r\n\r\nYes =E2=80=94 Tuesday.\r\n"

    assert Mime.text_body(raw) == "Yes — Tuesday."
  end

  test "an HTML-only message loses its tags" do
    raw =
      "From: a@b.test\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>Call me <b>Tuesday</b></p>\r\n"

    assert Mime.text_body(raw) =~ "Tuesday"
    refute Mime.text_body(raw) =~ "<b>"
  end

  test "something that won't parse still gives what follows the headers" do
    assert Mime.text_body("Subject: x\r\n\r\nplain words") == "plain words"
  end

  test "knows a whole message from a body" do
    assert Mime.raw_message?("MIME-Version: 1.0\r\nContent-Type: text/plain\r\n\r\nhi")
    refute Mime.raw_message?("Yes, send me the demo link.")
  end
end
