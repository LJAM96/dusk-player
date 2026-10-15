/* ============================================
   App Store reviews shown on the website.

   This is the ONLY file to touch when the reviews change. The array is plain
   JSON in the shape App Store Connect returns, so an export can be pasted in
   as-is. Fields used: rating (only 5 is shown), title, body, reviewerNickname.
   Others are kept but ignored. Cards appear in array order, four per row.
   Copy texts verbatim; don't fix typos or invent names. See
   docs/website-reviews.md.
   ============================================ */

window.DUSK_REVIEWS = [
  {"id":"00000192-f4ee-5b03-54f9-496f00000000","rating":5,"title":"Absolutely brilliant player! Please consider adding SharePlay!","body":"Dusk is hands-down one of the cleanest, fastest native Plex players on iOS and tvOS. It makes watching personal media such as an absolute joy!\nAs a feature request, please consider implementing Apple's native SharePlay (GroupActivities). Having a native \"Watch Together\" option that runs over FaceTime would make this the ultimate app for long-distance family and couples. Because SharePlay handles the stream sync, live voice chat, and automatic audio ducking (lowering the movie volume when you talk) perfectly out-of-the-box, it would fit beautifully with Dusk's native design. Thank you for this amazing app!","reviewerNickname":"adrian8572mac","createdDate":"2026-07-16T08:00:10-07:00","territory":"ROU"},
  {"id":"00000192-f4ee-5b03-67da-23ca00000000","rating":5,"title":"Thank you","body":"I really love this application. So much better than the Plex app which crashes all the time and is bloated. I haven’t checked but do you guys accept tips? I’d like to give a few dollars back in return for such a nice app.\n\nEdit: Found it and took up a small subscription. I hope it helps.","reviewerNickname":"Richad","createdDate":"2026-10-04T08:54:00-07:00","territory":"AUS"},
  {"id":"00000192-f4ee-5b03-4839-d94000000000","rating":5,"title":"Superb Plex Player","body":"This is the Plex player we deserve and the dev has done a wonderful job. \n\nJust needs two things to make it perfect. User switching and download media to device for offline use.","reviewerNickname":"Lord Topley","createdDate":"2026-05-23T05:57:18-07:00","territory":"GBR"},
  {"id":"00000192-f4ee-5b03-69d0-f7b300000000","rating":5,"title":"Promising","body":"Very promising Plex front-end alternative. Clean, functional, and minimal - thank you! Keep up the good work","reviewerNickname":"Adiamonte","createdDate":"2026-10-12T20:16:14-07:00","territory":"USA"}
];
