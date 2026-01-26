/* initialize jsPsych */
// var jsPsych = initJsPsych({
//
// });

/* create timelines */
const study = "occupation";
let stim_show;

if (study === "occupation") {
  stim_show = "their occupation";
} else if (study === "name") {
  stim_show = "their name";
} else {
  stim_show = "a photo of them";
}
// const pavlovia_init = {
//   type: jsPsychPavlovia,
//   command: "init"};
//   instructions_timeline.push(pavlovia_init);
  /* finish connection with pavlovia.org */
// var pavlovia_finish = {
//   type: jsPsychPavlovia,
//   command: "finish"};
//   instructions_timeline
// const urlParams = new URLSearchParams(window.location.search);
// const participantID = urlParams.get("participant") || "f001";


console.log(stim_show); // for testing


var instructions_timeline = [];
var matching_timeline = [];
var pre_rating_timeline = [];
var trustgame_timeline = [];
var post_rating_timeline = [];


/* define welcome message trial */
var welcome = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus: "Welcome to the experiment! Press SPACE to begin.",
  choices: [' ']
};
instructions_timeline.push(welcome);

/* define instructions trial */
var instructions1 = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  `<p> Hi! Welcome to the Investment Game. </p>
    <p>This game involves you making decisions with other study participants.</p>
    <p>In each round, you will be making a decision involving just one study partner at a time.</p>
  <p>Press ENTER for more instructions</p>
  `,
  choices: ['Enter', 'ENTER']
};
instructions_timeline.push(instructions1);

var instructions2 = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  ` <p> You'll begin each trial with $8 and use your mouse to decide how much of your endowment to <strong>KEEP</strong> for yourself and how much to <strong>SEND</strong> to your current partner.</p>
    <p>Any amount you send to your partner will be <strong>TRIPLED</strong> before it reaches your partner. </p>
    <p> For example: If you send <strong>$2</strong>, your partner will receive <strong>$6</strong>. </p>
    <p> Press SPACE to continue </p>
  `,
  choices: [' ']
};
instructions_timeline.push(instructions2);

var instructions3 = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  `<p>You will have FIVE seconds to make your decision, so make sure to answer quickly.</p>
  <p>If you do not respond within five seconds, <strong>all</strong> of the $8 will be sent to your partner that round.</p>
  <p> After you decide what to send to your partner, your partner will decide how much of that amount to return back to you. </p>
  <p>Press ENTER to continue.</p>
  `,
  choices: ['Enter','ENTER']
};
instructions_timeline.push(instructions3);

var instructions4 = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  `<p>After you decide what to send to your partner, your partner will decide how much of that amount to return back to you.</p>
  <p>Partners can choose to return ether <strong>HALF</strong> of their received amount or <strong>NONE</strong> of it. </p>
  <p>Each partner will make their decision AFTER receiving your investment, and their response will appear on your screen.</p>
  <p>For example, if your partner received <strong>$6</strong>, they could either return <strong>$3</strong> or <strong>$0</strong>. </p>
  <p>Press SPACE to continue.
  `,
  choices: [' ']
};
instructions_timeline.push(instructions4);

/* start matching */
var matching_intro = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
  `<p>You will now be matched to play the game with other study participants currently at partner universities.</p>
  <p> </p>
  <p>Before starting the game, you will have the opportunity to view profiles provided by these participants. </p>
  <p> Please press ENTER to be matched. </p>
  `,
  choices: ['Enter','ENTER'],
  on_finish: function () {
   hideProgressBar(); // 🔹 ensure hidden before matching
 }
};
matching_timeline.push(matching_intro);
console.log(matching_timeline);
/* start the experiment */


//
// jsPsych.run(instructions_timeline, matching_timeline);
