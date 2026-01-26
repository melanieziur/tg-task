// Make sure you have a timeline array for this phase
var pre_rating_timeline = [];

// Intro screen
var partner_intro = {
  type: jsPsychHtmlKeyboardResponse,
  stimulus:
    `<p>You will now be asked to provide a rating of your partners.</p>
    <p>Please use the slider provided to indicate your response.  <p>
     <p>Press SPACE to rate each partner.</p>`,
  choices: [' '], // just space
  on_finish: function () {
    hideProgressBar();
  }
};
pre_rating_timeline.push(partner_intro);

// Example: loop through partner stimuli
// Assume partnerStimuli is an array of objects {partner_id, condition, stimulus}
partnerStimuli.forEach(stim => {

  // Create a slider trial for each partner
  var rating_trial = {
    type: jsPsychHtmlSliderResponse,

    stimulus: function () {
      const content =
        study === "face"
          ? `<img src="${stim}" style="width:500px;">`
          : `<p style="font-size:32px;">${stim}</p>`;

      return `
        <div style="width:600px; margin:auto;">
          <p>
            In your opinion, how <strong>trustworthy</strong> is this partner likely to be?
            That is, how much does this person tend to be relied on as honest and truthful?
          </p>

          ${content}

          <p style="margin-top:20px;">
            <strong>Your rating:</strong>
            <span id="slider-value-display">50</span>
          </p>
        </div>
      `;
    },

    min: 0,
    max: 100,
    start: 50,
    step: 1,
    labels: ['0 - Not trustworthy at all', '100 - Very trustworthy'],
    require_movement: true,

    on_load: function () {
      const slider = document.querySelector(
        '#jspsych-html-slider-response-response'
      );
      const display = document.querySelector('#slider-value-display');

      // Set initial value
      display.textContent = slider.value;

      // Update live as slider moves
      slider.addEventListener('input', () => {
        display.textContent = slider.value;
      });
    },

    on_finish: function (data) {
      data.partner_id = stim.partner_id;
      data.condition = stim.condition;
      console.log("Submitted rating:", data.response);
    }
  };


  pre_rating_timeline.push(rating_trial);

});
console.log("got here")
