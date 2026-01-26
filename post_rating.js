/* start matching */
var partner_intro = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  `<p>You will now be asked to provide a rating of your partners</p>
  <p> These are other participants currently completing this study as part of a collaboration with partner universities. </p>
  <p> They each provided a profile in the form of <strong> ${stim_show} </strong> for your view.</p>
  <p>Before starting the game, you will have the opportunity to view these profiles to get a sense of who you are playing with. </p>
  <p> Please press SPACE to rate each partner </p>
  `,
  choices: [' ','space'],
  on_finish: function () {
   hideProgressBar(); // 🔹 ensure hidden before matching
 }
};
matching_timeline.push(partner_intro);
